// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/intrinsics.dart';
import 'package:dart2wasm/param_info.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/visitor.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

/// Code generation pre-pass with the following responsibilities:
///
/// - Compare the Wasm type of the value produced by an operation to the Wasm
///   type expected by the consumer of the value to automatically inject boxing,
///   unboxing, null checks and downcasts.
///
/// - Inject drop instructions for value-producing expressions in void context.
///
/// - Mark assignments which occur in non-void context so the code generator
///   knows to leave the value on the stack.
///
/// - Note the expected type of some expressions that need to know it
///   (conditional expressions and null literals/constants).
///
/// - Identify intrinsified calls and inject intrinsic code (via the
///   Intrinsifier).
class BodyAnalyzer extends Visitor<w.ValueType>
    with VisitorThrowingMixin<w.ValueType> {
  final CodeGenerator codeGen;
  final Translator translator;
  late final Intrinsifier intrinsifier;
  final w.ValueType voidMarker;
  final objectType;

  Set<Expression> preserved = {};
  Map<Expression, CodeGenCallback> inject = {};
  Map<Node, w.ValueType> expressionType = {};
  bool specializeThis = false;

  w.ValueType expectedType;
  w.ValueType returnType;

  BodyAnalyzer(this.codeGen)
      : translator = codeGen.translator,
        voidMarker = codeGen.voidMarker,
        objectType = codeGen.translator
            .translateType(codeGen.translator.coreTypes.objectNullableRawType),
        expectedType = codeGen.translator.voidMarker,
        returnType = codeGen.returnType {
    intrinsifier = Intrinsifier(this);
  }

  void analyzeMember(Member member) {
    if (member is Constructor) {
      Class cls = member.enclosingClass;
      for (Field field in cls.fields) {
        if (field.isInstanceMember && field.initializer != null) {
          wrapExpression(field.initializer!,
              translateType(field.type).withNullability(true));
        }
      }
      visitList(member.initializers, this);
    }
    member.function!.body!.accept(this);
  }

  w.ValueType translateType(DartType type) => translator.translateType(type);

  w.ValueType typeForLocal(w.ValueType type) => translator.typeForLocal(type);

  w.ValueType typeOfExp(Expression exp) {
    return translateType(exp.getStaticType(codeGen.typeContext));
  }

  w.ValueType wrapExpression(Expression exp, w.ValueType expectedType) {
    this.expectedType = expectedType;
    w.ValueType resultType = exp.accept(this);
    CodeGenCallback? conversion = translator.convertTypeCallback(
        resultType, expectedType, (b) => exp.accept(codeGen));
    if (conversion != null) {
      inject[exp] = conversion;
      return expectedType;
    }
    return resultType;
  }

  visitFieldInitializer(FieldInitializer node) {
    return wrapExpression(
        node.value, translateType(node.field.type).withNullability(true));
  }

  visitRedirectingInitializer(RedirectingInitializer node) {
    return _visitArguments(node.arguments, node.target.reference, 1);
  }

  visitSuperInitializer(SuperInitializer node) {
    if (translator.functions.containsKey(node.target.reference)) {
      return _visitArguments(node.arguments, node.target.reference, 1);
    }
    assert(node.arguments.positional.isEmpty && node.arguments.named.isEmpty);
    return voidMarker;
  }

  visitExpressionStatement(ExpressionStatement node) {
    return wrapExpression(node.expression, voidMarker);
  }

  visitBlock(Block node) {
    visitList(node.statements, this);
    return voidMarker;
  }

  visitEmptyStatement(EmptyStatement node) => voidMarker;

  visitWhileStatement(WhileStatement node) {
    wrapExpression(node.condition, w.NumType.i32);
    node.body.accept(this);
    return voidMarker;
  }

  visitDoStatement(DoStatement node) {
    node.body.accept(this);
    wrapExpression(node.condition, w.NumType.i32);
    return voidMarker;
  }

  visitForStatement(ForStatement node) {
    visitList(node.variables, this);
    if (node.condition != null) {
      wrapExpression(node.condition!, w.NumType.i32);
    }
    for (Expression update in node.updates) {
      wrapExpression(update, voidMarker);
    }
    node.body.accept(this);
    return voidMarker;
  }

  visitIfStatement(IfStatement node) {
    wrapExpression(node.condition, w.NumType.i32);
    node.then.accept(this);
    node.otherwise?.accept(this);
    return voidMarker;
  }

  visitReturnStatement(ReturnStatement node) {
    if (node.expression != null) {
      wrapExpression(node.expression!, returnType);
    }
    return voidMarker;
  }

  visitVariableDeclaration(VariableDeclaration node) {
    Expression? initializer = node.initializer;
    if (initializer != null) {
      wrapExpression(initializer, typeForLocal(translateType(node.type)));
    }
    return voidMarker;
  }

  w.ValueType defaultExpression(Expression node) {
    throw "Unsupported expression in body analyzer: $node";
  }

  w.ValueType visitVariableGet(VariableGet node) {
    TreeNode? variableParent = node.variable.parent;
    if (variableParent is FunctionNode) {
      if (variableParent.parent is LocalFunction) {
        // Lambda parameter
        return objectType;
      }
      assert(variableParent.parent == codeGen.member);
      return codeGen.locals[node.variable]!.type;
    }
    return typeForLocal(translateType(node.variable.type));
    // TODO: Create and set promoted local to be able to use promoted type.
    DartType? promotedDartType = node.promotedType;
    if (promotedDartType != null) {
      w.ValueType promotedType = translateType(promotedDartType);
      if (promotedType is! w.RefType) {
        // Primitive types are assigned to an accompanying promoted local at
        // promotion.
        return promotedType;
      }
    }
  }

  w.ValueType visitVariableSet(VariableSet node) {
    w.ValueType expectedType = this.expectedType;
    w.ValueType localType = typeForLocal(translateType(node.variable.type));
    wrapExpression(node.value, localType);
    if (expectedType != voidMarker) {
      preserved.add(node);
      return localType;
    }
    return voidMarker;
  }

  w.ValueType visitStaticGet(StaticGet node) {
    Member target = node.target;
    assert(!target.isInstanceMember);
    if (target is Field) {
      w.Global global = translator.globals.getGlobal(target);
      return global.type.type;
    } else {
      assert(target is Procedure && target.isGetter);
      w.FunctionType ftype = translator.functions[target.reference]!.type;
      return translator.outputOrVoid(ftype.outputs);
    }
  }

  w.ValueType visitStaticSet(StaticSet node) {
    w.ValueType expectedType = this.expectedType;
    Member target = node.target;
    assert(!target.isInstanceMember);
    w.ValueType valueType;
    if (target is Field) {
      w.Global global = translator.globals.getGlobal(target);
      valueType = global.type.type;
    } else {
      assert(target is Procedure && target.isSetter);
      w.FunctionType ftype = translator.functions[target.reference]!.type;
      assert(ftype.outputs.isEmpty);
      valueType = ftype.inputs.single;
    }
    wrapExpression(node.value, valueType);
    if (expectedType != voidMarker) {
      preserved.add(node);
      return typeForLocal(valueType);
    }
    return voidMarker;
  }

  w.ValueType visitInstanceGet(InstanceGet node) {
    Member? singleTarget = translator.singleTarget(
        node.interfaceTarget, node.receiver.getStaticType(codeGen.typeContext),
        setter: false);
    w.ValueType receiverType;
    w.ValueType resultType;
    if (singleTarget is Field) {
      // Direct field access
      w.StructType struct =
          translator.classInfo[singleTarget.enclosingClass]!.struct;
      receiverType = w.RefType.def(struct, nullable: true);
      resultType =
          struct.fields[translator.fieldIndex[singleTarget]!].type.unpacked;
    } else {
      // Instance call of getter
      w.ValueType? intrinsicResult =
          intrinsifier.getInstanceGetterIntrinsic(node);
      if (intrinsicResult != null) return intrinsicResult;
      int selectorId = translator.tableSelectorAssigner
          .getterSelectorId(node.interfaceTarget);
      w.FunctionType signature =
          translator.dispatchTable.selectorInfo[selectorId]!.signature;
      receiverType = signature.inputs[0];
      resultType = signature.outputs.single;
    }
    wrapExpression(node.receiver, receiverType);
    return resultType;
  }

  w.ValueType visitInstanceSet(InstanceSet node) {
    w.ValueType expectedType = this.expectedType;
    Member? singleTarget = translator.singleTarget(
        node.interfaceTarget, node.receiver.getStaticType(codeGen.typeContext),
        setter: false);
    w.ValueType receiverType;
    w.ValueType valueType;
    if (singleTarget is Field) {
      // Direct field access
      w.StructType struct =
          translator.classInfo[singleTarget.enclosingClass]!.struct;
      receiverType = w.RefType.def(struct, nullable: true);
      valueType =
          struct.fields[translator.fieldIndex[singleTarget]!].type.unpacked;
    } else {
      // Instance call of setter
      int selectorId = translator.tableSelectorAssigner
          .methodOrSetterSelectorId(node.interfaceTarget);
      w.FunctionType signature =
          translator.dispatchTable.selectorInfo[selectorId]!.signature;
      receiverType = signature.inputs[0];
      valueType = signature.inputs[1];
    }
    wrapExpression(node.receiver, receiverType);
    wrapExpression(node.value, valueType);
    if (expectedType != voidMarker) {
      preserved.add(node);
      return typeForLocal(valueType);
    }
    return voidMarker;
  }

  w.ValueType _visitArguments(
      Arguments arguments, Reference target, int signatureOffset,
      {void Function(w.ValueType)? typeReceiver}) {
    final w.FunctionType signature = translator.signatureFor(target);
    final ParameterInfo paramInfo = translator.paramInfoFor(target);
    typeReceiver?.call(signature.inputs[0]);
    for (int i = 0; i < arguments.positional.length; i++) {
      final int index = signatureOffset + i;
      wrapExpression(arguments.positional[i], signature.inputs[index]);
    }
    for (var param in arguments.named) {
      final int index = signatureOffset + paramInfo.nameIndex[param.name]!;
      wrapExpression(param.value, typeForLocal(signature.inputs[index]));
    }

    // Visit default values to fill in types for null constants.
    for (int i = arguments.positional.length;
        i < paramInfo.positional.length;
        i++) {
      Constant constant = paramInfo.positional[i]!;
      if (constant is NullConstant) {
        final int index = signatureOffset + i;
        _rememberNullType(constant, signature.inputs[index]);
      }
    }
    for (String name in paramInfo.names) {
      Constant constant = paramInfo.named[name]!;
      if (constant is NullConstant) {
        final int index = signatureOffset + paramInfo.nameIndex[name]!;
        _rememberNullType(constant, signature.inputs[index]);
      }
    }

    return translator.outputOrVoid(signature.outputs);
  }

  w.ValueType _visitThis(w.ValueType expectedType) {
    w.ValueType thisParameterType = codeGen.paramLocals[0].type;
    if (expectedType == voidMarker ||
        thisParameterType.isSubtypeOf(expectedType)) {
      return typeForLocal(thisParameterType);
    }
    specializeThis = true;
    return typeForLocal(w.RefType.def(
        translator.classInfo[codeGen.member.enclosingClass]!.repr.struct,
        nullable: false));
  }

  w.ValueType visitInstanceInvocation(InstanceInvocation node) {
    w.ValueType? intrinsicResult = intrinsifier.getInstanceIntrinsic(node);
    if (intrinsicResult != null) return intrinsicResult;
    return _visitArguments(node.arguments, node.interfaceTarget.reference, 1,
        typeReceiver: (t) => wrapExpression(node.receiver, t));
  }

  w.ValueType visitEqualsNull(EqualsNull node) {
    wrapExpression(node.expression, objectType);
    return w.NumType.i32;
  }

  w.ValueType visitEqualsCall(EqualsCall node) {
    w.ValueType? intrinsicResult = intrinsifier.getEqualsIntrinsic(node);
    if (intrinsicResult != null) return intrinsicResult;
    wrapExpression(node.left, objectType);
    wrapExpression(node.right, objectType);
    return w.NumType.i32;
  }

  w.ValueType visitSuperMethodInvocation(SuperMethodInvocation node) {
    return _visitArguments(node.arguments, node.interfaceTarget!.reference, 1,
        typeReceiver: _visitThis);
  }

  w.ValueType visitStaticInvocation(StaticInvocation node) {
    w.ValueType? intrinsicResult = intrinsifier.getStaticIntrinsic(node);
    if (intrinsicResult != null) return intrinsicResult;
    return _visitArguments(node.arguments, node.target.reference, 0);
  }

  w.ValueType visitConstructorInvocation(ConstructorInvocation node) {
    _visitArguments(node.arguments, node.target.reference, 1);
    if (expectedType != voidMarker) {
      preserved.add(node);
      ClassInfo info = translator.classInfo[node.target.enclosingClass]!;
      return typeForLocal(w.RefType.def(info.struct, nullable: false));
    }
    return voidMarker;
  }

  w.ValueType visitFunctionExpression(FunctionExpression node) {
    w.ValueType savedReturnType = returnType;
    returnType = objectType;
    node.function.body!.accept(this);
    returnType = savedReturnType;
    return typeOfExp(node);
  }

  w.ValueType visitFunctionInvocation(FunctionInvocation node) {
    int parameterCount = node.arguments.positional.length;
    wrapExpression(node.receiver, typeOfExp(node.receiver));

    int signatureOffset = 1;
    final w.FunctionType signature = translator.functionType(parameterCount);
    for (int i = 0; i < node.arguments.positional.length; i++) {
      final int index = signatureOffset + i;
      wrapExpression(node.arguments.positional[i], signature.inputs[index]);
    }

    return signature.outputs.single;
  }

  w.ValueType visitNot(Not node) {
    wrapExpression(node.operand, w.NumType.i32);
    return w.NumType.i32;
  }

  w.ValueType visitNullCheck(NullCheck node) {
    // TODO: Actual check, throwing an exception.
    return wrapExpression(node.operand, expectedType);
  }

  w.ValueType visitLogicalExpression(LogicalExpression node) {
    wrapExpression(node.left, w.NumType.i32);
    wrapExpression(node.right, w.NumType.i32);
    return w.NumType.i32;
  }

  w.ValueType visitConditionalExpression(ConditionalExpression node) {
    w.ValueType expectedType = this.expectedType;
    expressionType[node] = expectedType;
    wrapExpression(node.condition, w.NumType.i32);
    wrapExpression(node.then, expectedType);
    wrapExpression(node.otherwise, expectedType);
    return expectedType;
  }

  w.ValueType visitIsExpression(IsExpression node) {
    wrapExpression(node.operand, objectType);
    return w.NumType.i32;
  }

  w.ValueType visitAsExpression(AsExpression node) {
    // TODO: Actual check, throwing an exception.
    return wrapExpression(node.operand, expectedType);
  }

  w.ValueType visitThisExpression(ThisExpression node) {
    return _visitThis(expectedType);
  }

  w.ValueType visitConstantExpression(ConstantExpression node) {
    if (node.constant is NullConstant) {
      return _rememberNullType(node);
    }
    return typeOfExp(node);
  }

  w.ValueType visitBoolLiteral(BoolLiteral node) {
    return w.NumType.i32;
  }

  w.ValueType visitIntLiteral(IntLiteral node) {
    return w.NumType.i64;
  }

  w.ValueType visitDoubleLiteral(DoubleLiteral node) {
    return w.NumType.f64;
  }

  w.ValueType visitStringLiteral(StringLiteral node) {
    return translateType(translator.coreTypes.stringNonNullableRawType);
  }

  w.ValueType visitStringConstant(StringConstant node) {
    return translateType(translator.coreTypes.stringNonNullableRawType);
  }

  w.ValueType visitNullLiteral(NullLiteral node) {
    return _rememberNullType(node);
  }

  w.ValueType _rememberNullType(Node node, [w.ValueType? type]) {
    type ??= expectedType;
    return expressionType[node] = type.withNullability(true);
  }

  w.ValueType visitLet(Let node) {
    w.ValueType expectedType = this.expectedType;
    wrapExpression(node.variable.initializer!,
        typeForLocal(translateType(node.variable.type)));
    return wrapExpression(node.body, expectedType);
  }

  w.ValueType visitBlockExpression(BlockExpression node) {
    w.ValueType expectedType = this.expectedType;
    node.body.accept(this);
    return wrapExpression(node.value, expectedType);
  }

  w.ValueType visitStringConcatenation(StringConcatenation node) {
    for (Expression expression in node.expressions) {
      wrapExpression(expression, objectType);
    }
    return translateType(translator.coreTypes.stringNonNullableRawType);
  }

  w.ValueType visitThrow(Throw node) {
    w.ValueType expectedType = this.expectedType;
    wrapExpression(node.expression, typeOfExp(node.expression));
    return expectedType;
  }
}
