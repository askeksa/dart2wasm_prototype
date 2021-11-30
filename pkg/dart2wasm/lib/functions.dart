// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/tearoff_reference.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/external_name.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class FunctionCollector extends MemberVisitor1<w.FunctionType, Reference> {
  final Translator translator;
  final Map<Reference, w.BaseFunction> _functions = {};
  final Map<Reference, String> exports = {};
  final List<Reference> pending = [];

  FunctionCollector(this.translator);

  w.Module get m => translator.m;
  CoreTypes get coreTypes => translator.coreTypes;

  String? _findExportName(Member member) {
    for (Expression annotation in member.annotations) {
      if (annotation is ConstantExpression) {
        Constant constant = annotation.constant;
        if (constant is InstanceConstant) {
          if (constant.classNode == coreTypes.pragmaClass) {
            Constant? name =
                constant.fieldValues[coreTypes.pragmaName.fieldReference];
            if (name is StringConstant && name.value == "wasm:export") {
              Constant? options =
                  constant.fieldValues[coreTypes.pragmaOptions.fieldReference];
              if (options is StringConstant) {
                return options.value;
              }
              return member.name.text;
            }
          }
        }
      }
    }
    return null;
  }

  void collectImportsAndExports() {
    for (Library library in translator.libraries) {
      for (Procedure procedure in library.procedures) {
        _importOrExport(procedure);
      }
      for (Class cls in library.classes) {
        for (Procedure procedure in cls.procedures) {
          _importOrExport(procedure);
        }
      }
    }
  }

  void _importOrExport(Procedure procedure) {
    String? externalName = getExternalName(translator.coreTypes, procedure);
    if (externalName != null) {
      int dot = externalName.indexOf('.');
      if (dot != -1) {
        assert(!procedure.isInstanceMember);
        String module = externalName.substring(0, dot);
        String name = externalName.substring(dot + 1);
        w.FunctionType ftype = _makeFunctionType(
            procedure.reference, procedure.function.returnType, null,
            isImportOrExport: true);
        _functions[procedure.reference] = m.importFunction(module, name, ftype);
      }
    }
    String? exportName = _findExportName(procedure);
    if (exportName != null) {
      addExport(procedure.reference, exportName);
    }
  }

  void addExport(Reference target, String exportName) {
    exports[target] = exportName;
  }

  void initExports() {
    for (Reference target in exports.keys) {
      pending.add(target);
      Procedure node = target.asProcedure;
      assert(!node.isInstanceMember);
      assert(!node.isGetter);
      w.FunctionType ftype = _makeFunctionType(
          target, node.function.returnType, null,
          isImportOrExport: true);
      _functions[target] = m.addFunction(ftype);
    }
  }

  w.BaseFunction? getExistingFunction(Reference target) {
    return _functions[target];
  }

  w.BaseFunction getFunction(Reference target) {
    return _functions.putIfAbsent(target, () {
      pending.add(target);
      w.FunctionType ftype = target.isTearOffReference
          ? translator.dispatchTable.selectorForTarget(target).signature
          : target.asMember.accept1(this, target);
      return m.addFunction(ftype);
    });
  }

  void activateSelector(SelectorInfo selector) {
    for (Reference target in selector.targets.values) {
      if (!target.asMember.isAbstract) {
        getFunction(target);
      }
    }
  }

  w.FunctionType defaultMember(Member node, Reference target) {
    throw "No Wasm function for member: $node";
  }

  w.FunctionType visitField(Field node, Reference target) {
    if (!node.isInstanceMember) {
      if (target == node.fieldReference) {
        // Static field initializer function
        return _makeFunctionType(target, node.type, null);
      }
      String kind = target == node.setterReference ? "setter" : "getter";
      throw "No implicit $kind function for static field: $node";
    }
    return translator.dispatchTable.selectorForTarget(target).signature;
  }

  w.FunctionType visitProcedure(Procedure node, Reference target) {
    assert(!node.isAbstract);
    return node.isInstanceMember
        ? translator.dispatchTable.selectorForTarget(node.reference).signature
        : _makeFunctionType(target, node.function.returnType, null);
  }

  w.FunctionType visitConstructor(Constructor node, Reference target) {
    return _makeFunctionType(target, VoidType(),
        translator.classInfo[node.enclosingClass]!.nonNullableType);
  }

  w.FunctionType _makeFunctionType(
      Reference target, DartType returnType, w.ValueType? receiverType,
      {bool isImportOrExport = false}) {
    Member member = target.asMember;
    int typeParamCount = 0;
    Iterable<DartType> params;
    if (member is Field) {
      params = [if (target.isImplicitSetter) member.setterType];
    } else {
      FunctionNode function = member.function!;
      typeParamCount = (member is Constructor
              ? member.enclosingClass.typeParameters
              : function.typeParameters)
          .length;
      List<String> names = [for (var p in function.namedParameters) p.name!]
        ..sort();
      Map<String, DartType> nameTypes = {
        for (var p in function.namedParameters) p.name!: p.type
      };
      params = [
        for (var p in function.positionalParameters) p.type,
        for (String name in names) nameTypes[name]!
      ];
      function.positionalParameters.map((p) => p.type);
    }

    List<w.ValueType> typeParameters = List.filled(typeParamCount,
        translator.classInfo[translator.typeClass]!.nullableType);

    // The JS embedder will not accept Wasm struct types as parameter or return
    // types for functions called from JS. We need to use eqref instead.
    w.ValueType adjustExternalType(w.ValueType type) {
      if (isImportOrExport && type.isSubtypeOf(w.RefType.eq())) {
        return w.RefType.eq();
      }
      return type;
    }

    List<w.ValueType> inputs = [];
    if (receiverType != null) {
      inputs.add(adjustExternalType(receiverType));
    }
    inputs.addAll(typeParameters.map(adjustExternalType));
    inputs.addAll(
        params.map((t) => adjustExternalType(translator.translateType(t))));

    List<w.ValueType> outputs = returnType is VoidType ||
            returnType is NeverType ||
            returnType is NullType
        ? const []
        : [adjustExternalType(translator.translateType(returnType))];

    return m.addFunctionType(inputs, outputs);
  }
}
