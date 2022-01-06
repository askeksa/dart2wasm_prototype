// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

import 'package:dart2wasm/translator.dart';

class Globals {
  final Translator translator;

  final Map<Field, w.Global> globals = {};
  final Map<Field, w.BaseFunction> globalInitializers = {};
  final Map<Field, w.Global> globalInitializedFlag = {};
  final Map<w.HeapType, w.DefinedGlobal> dummyValues = {};

  Globals(this.translator) {
    if (translator.options.localNullability) {
      _initDummyValues();
    }
  }

  void _initDummyValues() {
    // Create dummy struct for anyref/eqref/dataref dummy values
    w.StructType structType = translator.m.addStructType("#Dummy");
    w.RefType type = w.RefType.def(structType, nullable: false);
    w.DefinedGlobal global =
        translator.m.addGlobal(w.GlobalType(type, mutable: false));
    w.Instructions ib = global.initializer;
    translator.struct_new(ib, structType);
    ib.end();
    dummyValues[w.HeapType.any] = global;
    dummyValues[w.HeapType.eq] = global;
    dummyValues[w.HeapType.data] = global;
  }

  w.Global? prepareDummyValue(w.ValueType type) {
    if (type is w.RefType && !type.nullable) {
      w.HeapType heapType = type.heapType;
      w.DefinedGlobal? global = dummyValues[heapType];
      if (global != null) return global;
      if (heapType is w.DefHeapType) {
        w.DefType defType = heapType.def;
        if (defType is w.StructType) {
          for (w.FieldType field in defType.fields) {
            prepareDummyValue(field.type.unpacked);
          }
          global = translator.m.addGlobal(w.GlobalType(type, mutable: false));
          w.Instructions ib = global.initializer;
          for (w.FieldType field in defType.fields) {
            instantiateDummyValue(ib, field.type.unpacked);
          }
          translator.struct_new(ib, defType);
          ib.end();
        } else if (defType is w.ArrayType) {
          global = translator.m.addGlobal(w.GlobalType(type, mutable: false));
          w.Instructions ib = global.initializer;
          translator.array_init(ib, defType, 0);
          ib.end();
        } else if (defType is w.FunctionType) {
          w.DefinedFunction function = translator.m.addFunction(defType);
          w.Instructions b = function.body;
          b.unreachable();
          b.end();
          global = translator.m.addGlobal(w.GlobalType(type, mutable: false));
          w.Instructions ib = global.initializer;
          ib.ref_func(function);
          ib.end();
        }
        dummyValues[heapType] = global!;
      }
      return global;
    }
  }

  void instantiateDummyValue(w.Instructions b, w.ValueType type) {
    w.Global? global = prepareDummyValue(type);
    switch (type) {
      case w.NumType.i32:
        b.i32_const(0);
        break;
      case w.NumType.i64:
        b.i64_const(0);
        break;
      case w.NumType.f32:
        b.f32_const(0);
        break;
      case w.NumType.f64:
        b.f64_const(0);
        break;
      default:
        if (type is w.RefType) {
          w.HeapType heapType = type.heapType;
          if (type.nullable) {
            b.ref_null(heapType);
          } else {
            b.global_get(global!);
          }
        } else {
          throw "Unsupported global type ${type} ($type)";
        }
        break;
    }
  }

  Constant? _getConstantInitializer(Field variable) {
    Expression? init = variable.initializer;
    if (init == null || init is NullLiteral) return NullConstant();
    if (init is ConstantExpression) return init.constant;
    if (init is IntLiteral) return IntConstant(init.value);
    if (init is DoubleLiteral) return DoubleConstant(init.value);
    if (init is BoolLiteral) return BoolConstant(init.value);
    if (init is StringLiteral) return StringConstant(init.value);
    return null;
  }

  w.Global getGlobal(Field variable) {
    assert(!variable.isLate);
    return globals.putIfAbsent(variable, () {
      w.ValueType type = translator.translateType(variable.type);
      Constant? init = _getConstantInitializer(variable);
      if (init != null && !translator.options.lazyConstants) {
        // Initialized to a constant
        translator.constants.ensureConstant(init);
        w.DefinedGlobal global = translator.m
            .addGlobal(w.GlobalType(type, mutable: !variable.isFinal));
        translator.constants
            .instantiateConstant(null, global.initializer, init, type);
        global.initializer.end();
        return global;
      } else {
        if (type is w.RefType && !type.nullable) {
          // Null signals uninitialized
          type = type.withNullability(true);
        } else {
          // Explicit initialization flag
          w.DefinedGlobal flag =
              translator.m.addGlobal(w.GlobalType(w.NumType.i32));
          flag.initializer.i32_const(0);
          flag.initializer.end();
          globalInitializedFlag[variable] = flag;
        }

        w.DefinedGlobal global = translator.m.addGlobal(w.GlobalType(type));
        instantiateDummyValue(global.initializer, type);
        global.initializer.end();

        globalInitializers[variable] =
            translator.functions.getFunction(variable.fieldReference);
        return global;
      }
    });
  }

  w.Global? getGlobalInitializedFlag(Field variable) {
    return globalInitializedFlag[variable];
  }

  w.ValueType readGlobal(w.Instructions b, Field variable) {
    w.Global global = getGlobal(variable);
    w.BaseFunction? initFunction = globalInitializers[variable];
    if (initFunction == null) {
      // Statically initialized
      b.global_get(global);
      return global.type.type;
    }
    w.Global? flag = globalInitializedFlag[variable];
    if (flag != null) {
      // Explicit initialization flag
      assert(global.type.type == initFunction.type.outputs.single);
      b.global_get(flag);
      b.if_(const [], [global.type.type]);
      b.global_get(global);
      b.else_();
      b.call(initFunction);
      b.end();
    } else {
      // Null signals uninitialized
      w.Label block = b.block(const [], [initFunction.type.outputs.single]);
      b.global_get(global);
      b.br_on_non_null(block);
      b.call(initFunction);
      b.end();
    }
    return initFunction.type.outputs.single;
  }
}
