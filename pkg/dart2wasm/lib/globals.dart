// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

import 'package:dart2wasm/translator.dart';

class Globals {
  final Translator translator;

  Map<Field, w.Global> globals = {};
  Map<w.HeapType, w.DefinedGlobal> dummyValues = {};

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

  w.Global getGlobal(Field variable) {
    return globals.putIfAbsent(variable, () {
      w.ValueType type =
          translator.translateType(variable.type).withNullability(true);
      w.DefinedGlobal global = translator.m.addGlobal(w.GlobalType(type));
      final w.Instructions b = global.initializer;
      instantiateDummyValue(b, type);
      b.end();
      return global;
    });
  }
}
