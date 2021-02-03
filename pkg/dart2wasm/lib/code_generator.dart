// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:kernel/ast.dart';
import 'package:kernel/type_environment.dart';
import 'package:kernel/visitor.dart';

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/intrinsics.dart';
import 'package:dart2wasm/translator.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class HasThis extends RecursiveVisitor<void> {
  bool found = false;

  bool hasThis(TreeNode node) {
    found = false;
    node.accept(this);
    return found;
  }

  void visitThisExpression(ThisExpression node) {
    found = true;
  }
}

class CodeGenerator extends Visitor<void> {
  Translator translator;

  late Member member;
  late StaticTypeContext typeContext;

  Map<VariableDeclaration, w.Local> locals = {};
  w.Local? thisLocal;
  late w.DefinedFunction function;
  late w.Instructions b;

  CodeGenerator(this.translator);

  void defaultNode(Node node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void defaultTreeNode(TreeNode node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void generate(Member member, w.DefinedFunction function) {
    if (member.isExternal) {
      print("External member: $member");
      return;
    }

    this.member = member;
    typeContext = StaticTypeContext(member, translator.typeEnvironment);

    List<VariableDeclaration> params = member.function.positionalParameters;
    int implicitParams = function.locals.length - params.length;
    assert(implicitParams == 0 || implicitParams == 1);
    for (int i = 0; i < params.length; i++) {
      locals[params[i]] = function.locals[implicitParams + i];
    }

    this.function = function;
    b = function.body;
    if (member is Constructor) {
      ClassInfo info = translator.classInfo[member.enclosingClass]!;
      thisLocal = function.locals[0];
      Class cls = member.enclosingClass;
      for (Field field in cls.fields) {
        if (field.isInstanceMember && field.initializer != null) {
          int fieldIndex = translator.fieldIndex[field]!;
          b.local_get(thisLocal!);
          field.initializer!.accept(this);
          b.struct_set(info.struct, fieldIndex);
        }
      }
      visitList(member.initializers, this);
    } else if (implicitParams == 1) {
      ClassInfo info = translator.classInfo[member.enclosingClass]!;
      if (function.locals[0].type == info.repr ||
          !HasThis().hasThis(member.function.body)) {
        thisLocal = function.locals[0];
      } else {
        thisLocal = function.addLocal(info.repr);
        b.local_get(function.locals[0]);
        b.global_get(info.rtt);
        b.ref_cast();
        b.local_set(thisLocal!);
      }
    } else {
      thisLocal = null;
    }
    member.function.body.accept(this);
    b.end();
  }

  void visitFieldInitializer(FieldInitializer node) {
    w.StructType struct = translator
        .classInfo[(node.parent as Constructor).enclosingClass]!.struct;
    int fieldIndex = translator.fieldIndex[node.field]!;

    b.local_get(thisLocal!);
    node.value.accept(this);
    b.struct_set(struct, fieldIndex);
  }

  void visitSuperInitializer(SuperInitializer node) {
    if ((node.parent as Constructor).enclosingClass.superclass?.superclass ==
        null) {
      return;
    }
    b.local_get(thisLocal!);
    node.arguments.accept(this);
    b.call(translator.functions[node.target]!);
  }

  void visitBlock(Block node) {
    node.visitChildren(this);
  }

  void visitBlockExpression(BlockExpression node) {
    node.visitChildren(this);
  }

  void visitVariableDeclaration(VariableDeclaration node) {
    w.ValueType type = translator.translateType(node.type);
    w.Local local = function.addLocal(type);
    locals[node] = local;
    if (node.initializer != null) {
      node.initializer!.accept(this);
      b.local_set(local);
    }
  }

  void visitEmptyStatement(EmptyStatement node) {}

  void visitExpressionStatement(ExpressionStatement node) {
    _visitVoidExpression(node.expression);
  }

  void _visitVoidExpression(Expression exp) {
    exp.accept(this);
    if (exp.getStaticType(typeContext) is! VoidType) {
      b.drop();
    }
  }

  void visitIfStatement(IfStatement node) {
    node.condition.accept(this);
    b.if_();
    node.then.accept(this);
    Statement? otherwise = node.otherwise;
    if (otherwise != null) {
      b.else_();
      otherwise.accept(this);
    }
    b.end();
  }

  void visitDoStatement(DoStatement node) {
    w.Label loop = b.loop();
    node.body.accept(this);
    node.condition.accept(this);
    b.br_if(loop);
    b.end();
  }

  void visitWhileStatement(WhileStatement node) {
    w.Label block = b.block();
    w.Label loop = b.loop();
    node.condition.accept(this);
    b.i32_eqz();
    b.br_if(block);
    node.body.accept(this);
    b.br(loop);
    b.end();
    b.end();
  }

  void visitForStatement(ForStatement node) {
    visitList(node.variables, this);
    w.Label block = b.block();
    w.Label loop = b.loop();
    node.condition.accept(this);
    b.i32_eqz();
    b.br_if(block);
    node.body.accept(this);
    for (Expression update in node.updates) {
      _visitVoidExpression(update);
    }
    b.br(loop);
    b.end();
    b.end();
  }

  void visitReturnStatement(ReturnStatement node) {
    node.visitChildren(this);
    b.return_();
  }

  void visitLet(Let node) {
    node.visitChildren(this);
  }

  void visitThisExpression(ThisExpression node) {
    b.local_get(thisLocal!);
  }

  void visitConstructorInvocation(ConstructorInvocation node) {
    ClassInfo info = translator.classInfo[node.target.enclosingClass]!;
    w.Local temp = function.addLocal(info.repr);
    b.global_get(info.rtt);
    b.struct_new_default_with_rtt(info.struct);
    b.local_tee(temp);
    b.i32_const(info.classId);
    b.struct_set(info.struct, 0);
    b.local_get(temp);
    node.arguments.accept(this);
    b.call(translator.functions[node.target]!);
    b.local_get(temp);
  }

  void visitStaticInvocation(StaticInvocation node) {
    node.arguments.accept(this);
    if (node.target == translator.coreTypes.identicalProcedure) {
      // TODO: Check for reference types
      b.ref_eq();
      return;
    }
    w.BaseFunction target = translator.functions[node.target]!;
    b.call(target);
  }

  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    b.local_get(thisLocal!);
    node.arguments.accept(this);
    w.BaseFunction target = translator.functions[node.interfaceTarget]!;
    b.call(target);
  }

  void visitInstanceInvocation(InstanceInvocation node) {
    node.receiver.accept(this);
    Member target = node.interfaceTarget;
    if (target is! Procedure) {
      throw "Unsupported invocation of $target";
    }
    if (target.kind == ProcedureKind.Operator) {
      node.arguments.accept(this);
      Intrinsic? intrinsic =
          translator.intrinsics.getOperatorIntrinsic(node, this);
      if (intrinsic != null) {
        intrinsic(this);
        return;
      }
    }
    _virtualCall(target, node.arguments, getter: false, setter: false);
  }

  void visitEqualsCall(EqualsCall node) {
    Intrinsic? intrinsic = translator.intrinsics.getEqualsIntrinsic(node, this);
    if (intrinsic != null) {
      node.left.accept(this);
      node.right.accept(this);
      intrinsic(this);
      return;
    }
    // TODO: virtual call
    node.left.accept(this);
    node.right.accept(this);
    b.ref_eq();
    if (node.isNot) {
      b.i32_eqz();
    }

    if (false)
      throw "EqualsCall of types "
          "${node.left.getStaticType(typeContext)} and "
          "${node.right.getStaticType(typeContext)} not supported";
  }

  void visitEqualsNull(EqualsNull node) {
    node.expression.accept(this);
    b.ref_is_null();
    if (node.isNot) {
      b.i32_eqz();
    }
  }

  void _virtualCall(Procedure interfaceTarget, Arguments arguments,
      {required bool getter, required bool setter}) {
    Member? singleTarget = translator.subtypes
        .getSingleTargetForInterfaceInvocation(interfaceTarget, setter: setter);
    if (singleTarget != null) {
      arguments.accept(this);
      w.BaseFunction target = translator.functions[singleTarget]!;
      b.call(target);
      return;
    }

    int selectorId = getter
        ? translator.tableSelectorAssigner.getterSelectorId(interfaceTarget)
        : translator.tableSelectorAssigner
            .methodOrSetterSelectorId(interfaceTarget);
    SelectorInfo selector = translator.dispatchTable.selectorInfo[selectorId]!;

    // Receiver is already on stack.
    w.StructType objectStruct = translator.classes[0].struct;
    w.Local temp =
        function.addLocal(w.RefType.def(objectStruct, nullable: true));
    b.local_tee(temp);
    arguments.accept(this);
    b.i32_const(selector.offset);
    b.local_get(temp);
    b.struct_get(objectStruct, 0);
    b.i32_add();
    b.call_indirect(selector.signature);
  }

  @override
  void visitVariableGet(VariableGet node) {
    w.Local? local = locals[node.variable];
    if (local == null) {
      throw "Read of undefined variable $node";
    }
    b.local_get(local);
  }

  @override
  void visitVariableSet(VariableSet node) {
    w.Local? local = locals[node.variable];
    if (local == null) {
      throw "Read of undefined variable $node";
    }
    node.value.accept(this);
    b.local_tee(local);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    Member target = node.interfaceTarget;
    if (target is Field) {
      node.receiver.accept(this);
      w.StructType struct = translator.classInfo[target.enclosingClass]!.struct;
      int fieldIndex = translator.fieldIndex[target]!;
      //b.rtt_canon(w.HeapType.def(struct));
      //b.ref_cast(w.HeapType.any, w.HeapType.def(struct));
      b.struct_get(struct, fieldIndex);
      return;
    } else if (target is Procedure && target.isGetter) {
      node.receiver.accept(this);
      _virtualCall(target, Arguments([]), getter: true, setter: false);
      return;
    }
    throw "InstanceGet of non-Field/Getter $target not supported";
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    Member target = node.interfaceTarget;
    if (target is Field) {
      node.receiver.accept(this);
      w.StructType struct = translator.classInfo[target.enclosingClass]!.struct;
      int fieldIndex = translator.fieldIndex[target]!;
      //b.rtt_canon(w.HeapType.def(struct));
      //b.ref_cast(w.HeapType.any, w.HeapType.def(struct));
      w.Local temp = function.addLocal(struct.fields[fieldIndex].type.unpacked);
      node.value.accept(this);
      b.local_tee(temp);
      b.struct_set(struct, fieldIndex);
      b.local_get(temp);
      return;
    }
    throw "InstanceSet of non-Field $target not supported";
  }

  void visitLogicalExpression(LogicalExpression node) {
    w.Label block = b.block([], [w.NumType.i32]);
    bool isAnd = node.operatorEnum == LogicalExpressionOperator.AND;
    b.i32_const(isAnd ? 0 : 1);
    node.left.accept(this);
    if (isAnd) b.i32_eqz();
    b.br_if(block);
    b.drop();
    node.right.accept(this);
    b.end();
  }

  void visitNot(Not node) {
    node.operand.accept(this);
    b.i32_eqz();
  }

  void visitConditionalExpression(ConditionalExpression node) {
    w.ValueType type =
        translator.translateType(node.getStaticType(typeContext));
    node.condition.accept(this);
    b.if_([], [type]);
    node.then.accept(this);
    b.else_();
    node.otherwise.accept(this);
    b.end();
  }

  void visitNullCheck(NullCheck node) {
    node.operand.accept(this);
  }

  void visitArguments(Arguments node) {
    visitList(node.positional, this);
    visitList(node.named.map((n) => n.value).toList(), this);
  }

  void visitConstantExpression(ConstantExpression node) {
    node.constant.accept(this);
  }

  void visitBoolLiteral(BoolLiteral node) {
    b.i32_const(node.value ? 1 : 0);
  }

  void visitIntLiteral(IntLiteral node) {
    b.i64_const(node.value);
  }

  void visitIntConstant(IntConstant node) {
    b.i64_const(node.value);
  }

  void visitDoubleLiteral(DoubleLiteral node) {
    b.f64_const(node.value);
  }

  void visitAsExpression(AsExpression node) {
    node.operand.accept(this);
    // TODO: Check
  }

  void visitNullLiteral(NullLiteral node) {
    TreeNode parent = node.parent;
    DartType type;
    if (parent is VariableDeclaration) {
      type = parent.type;
    } else if (parent is VariableSet) {
      type = parent.variable.type;
    } else if (parent is InstanceSet) {
      Member target = parent.interfaceTarget;
      type = target is Field
          ? target.type
          : target.function.positionalParameters.single.type;
    } else if (parent is Field) {
      type = parent.type;
    } else if (parent is FieldInitializer) {
      type = parent.field.type;
    } else if (parent is ReturnStatement) {
      type = member.function!.returnType;
    } else if (parent is AsExpression) {
      type = parent.type;
    } else {
      throw "Unsupported null literal context: $parent";
    }
    w.ValueType wasmType = translator.translateType(type);
    w.HeapType heapType =
        wasmType is w.RefType ? wasmType.heapType : w.HeapType.any;
    b.ref_null(heapType);
  }
}
