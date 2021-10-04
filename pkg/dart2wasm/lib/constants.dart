// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/type_algebra.dart' show substitute;
import 'package:kernel/visitor.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class ConstantInfo {
  Constant constant;
  w.DefinedGlobal global;
  w.DefinedFunction? function;

  ConstantInfo(this.constant, this.global, this.function);
}

typedef ConstantCodeGenerator = void Function(
    w.DefinedFunction?, w.Instructions);

class Constants {
  final Translator translator;
  final Map<Constant, ConstantInfo> constantInfo = {};
  final StringBuffer oneByteStrings = StringBuffer();
  final StringBuffer twoByteStrings = StringBuffer();
  late final w.DefinedFunction oneByteStringFunction;
  late final w.DefinedFunction twoByteStringFunction;
  late final w.DefinedGlobal emptyString;
  late final w.DefinedGlobal emptyTypeList;
  late final ClassInfo typeInfo = translator.classInfo[translator.typeClass]!;

  Constants(this.translator) {
    oneByteStringFunction = makeStringFunction(translator.oneByteStringClass);
    twoByteStringFunction = makeStringFunction(translator.twoByteStringClass);
    initEmptyString();
    initEmptyTypeList();
  }

  w.Module get m => translator.m;

  void initEmptyString() {
    ClassInfo info = translator.classInfo[translator.oneByteStringClass]!;
    w.ArrayType arrayType =
        ((info.struct.fields.last.type as w.RefType).heapType as w.DefHeapType)
            .def as w.ArrayType;

    w.RefType emptyStringType = info.nonNullableType;
    emptyString = m.addGlobal(w.GlobalType(emptyStringType, mutable: false));
    w.Instructions ib = emptyString.initializer;
    ib.i32_const(info.classId);
    ib.i32_const(initialIdentityHash);
    translator.array_init(ib, arrayType, 0);
    translator.struct_new(ib, info);
    ib.end();

    Constant emptyStringConstant = StringConstant("");
    constantInfo[emptyStringConstant] =
        ConstantInfo(emptyStringConstant, emptyString, null);
  }

  void initEmptyTypeList() {
    // TODO: Use unmodifiable list
    ClassInfo info = translator.classInfo[translator.fixedLengthListClass]!;
    w.RefType refType = info.struct.fields.last.type.unpacked as w.RefType;
    w.ArrayType arrayType =
        (refType.heapType as w.DefHeapType).def as w.ArrayType;

    // Create the empty type list with its type parameter uninitialized for now.
    w.RefType emptyListType = info.nonNullableType;
    emptyTypeList = m.addGlobal(w.GlobalType(emptyListType, mutable: false));
    w.Instructions ib = emptyTypeList.initializer;
    ib.i32_const(info.classId);
    ib.i32_const(initialIdentityHash);
    ib.ref_null(w.HeapType.def(typeInfo.struct)); // Initialized later
    ib.i64_const(0);
    translator.array_init(ib, arrayType, 0);
    translator.struct_new(ib, info);
    ib.end();

    // Initialize the type parameter of the empty type list to the type object
    // for _Type, which itself refers to the empty type list.
    w.Instructions b = translator.initFunction.body;
    b.global_get(emptyTypeList);
    instantiateConstant(
        translator.initFunction,
        b,
        TypeLiteralConstant(
            InterfaceType(translator.typeClass, Nullability.nonNullable)),
        typeInfo.nullableType);
    b.struct_set(info.struct,
        translator.typeParameterIndex[info.cls!.typeParameters.single]!);
  }

  void finalize() {
    Uint8List oneByteStringsAsBytes =
        Uint8List.fromList(oneByteStrings.toString().codeUnits);
    assert(Endian.host == Endian.little);
    Uint8List twoByteStringsAsBytes =
        Uint16List.fromList(twoByteStrings.toString().codeUnits)
            .buffer
            .asUint8List();
    Uint8List stringsAsBytes = (BytesBuilder()
          ..add(twoByteStringsAsBytes)
          ..add(oneByteStringsAsBytes))
        .toBytes();

    w.Memory stringMemory = m.addMemory(
        stringsAsBytes.length, stringsAsBytes.length)
      ..addData(0, stringsAsBytes);
    makeStringFunctionBody(translator.oneByteStringClass, oneByteStringFunction,
        (b) {
      b.i32_load8_u(stringMemory, twoByteStringsAsBytes.length);
    });
    makeStringFunctionBody(translator.twoByteStringClass, twoByteStringFunction,
        (b) {
      b.i32_const(1);
      b.i32_shl();
      b.i32_load16_u(stringMemory, 0);
    });
  }

  w.DefinedFunction makeStringFunction(Class cls) {
    ClassInfo info = translator.classInfo[cls]!;
    w.FunctionType ftype = m.addFunctionType(
        const [w.NumType.i32, w.NumType.i32], [info.nonNullableType]);
    return m.addFunction(ftype);
  }

  void makeStringFunctionBody(Class cls, w.DefinedFunction function,
      void Function(w.Instructions) emitLoad) {
    ClassInfo info = translator.classInfo[cls]!;
    w.ArrayType arrayType =
        ((info.struct.fields.last.type as w.RefType).heapType as w.DefHeapType)
            .def as w.ArrayType;

    w.Local offset = function.locals[0];
    w.Local length = function.locals[1];
    w.Local array = function.addLocal(
        translator.typeForLocal(w.RefType.def(arrayType, nullable: false)));
    w.Local index = function.addLocal(w.NumType.i32);

    w.Instructions b = function.body;
    b.local_get(length);
    translator.array_new_default(b, arrayType);
    b.local_set(array);

    b.i32_const(0);
    b.local_set(index);
    w.Label loop = b.loop();
    b.local_get(array);
    b.local_get(index);
    b.local_get(offset);
    b.local_get(index);
    b.i32_add();
    emitLoad(b);
    b.array_set(arrayType);
    b.local_get(index);
    b.i32_const(1);
    b.i32_add();
    b.local_tee(index);
    b.local_get(length);
    b.i32_lt_u();
    b.br_if(loop);
    b.end();

    b.i32_const(info.classId);
    b.i32_const(initialIdentityHash);
    b.local_get(array);
    translator.struct_new(b, info);
    b.end();
  }

  void instantiateConstant(w.DefinedFunction? function, w.Instructions b,
      Constant constant, w.ValueType expectedType) {
    ConstantInstantiator(this, function, b, expectedType).instantiate(constant);
  }
}

class ConstantInstantiator extends ConstantVisitor<w.ValueType> {
  final Constants constants;
  final w.DefinedFunction? function;
  final w.Instructions b;
  final w.ValueType expectedType;

  ConstantInstantiator(
      this.constants, this.function, this.b, this.expectedType);

  Translator get translator => constants.translator;
  w.Module get m => translator.m;

  void instantiate(Constant constant) {
    w.ValueType resultType = constant.accept(this);
    assert(!translator.needsConversion(resultType, expectedType));
    ConstantInfo? info = constants.constantInfo[constant];
    if (info != null) {
      w.ValueType globalType = info.global.type.type;
      if (globalType.nullable) {
        w.Label done = b.block([], [globalType.withNullability(false)]);
        b.global_get(info.global);
        b.br_on_non_null(done);
        b.call(info.function!);
        b.end();
      } else {
        b.global_get(info.global);
      }
    }
  }

  void instantiateLazyConstant(
      Constant constant, w.RefType type, ConstantCodeGenerator generator) {
    assert(!type.nullable);
    ConstantInfo? info = constants.constantInfo[constant];
    if (info == null) {
      w.DefinedGlobal global =
          m.addGlobal(w.GlobalType(type.withNullability(true)));
      global.initializer.ref_null(type.heapType);
      global.initializer.end();
      w.FunctionType ftype = m.addFunctionType([], [type]);
      w.DefinedFunction function = m.addFunction(ftype);
      generator(function, function.body);
      w.Local temp = function.addLocal(translator.typeForLocal(type));
      w.Instructions b2 = function.body;
      b2.local_tee(temp);
      b2.global_set(global);
      b2.local_get(temp);
      translator.convertType(function, temp.type, type);
      b2.end();
      info = ConstantInfo(constant, global, function);
      constants.constantInfo[constant] = info;
    }
  }

  w.ValueType defaultConstant(Constant node) {
    final text = "Not implemented: $node";
    print(text);
    b.comment(text);
    b.block([], [expectedType]);
    b.unreachable();
    b.end();
    return expectedType;
  }

  @override
  w.ValueType visitNullConstant(NullConstant node) {
    w.ValueType? expectedType = this.expectedType;
    if (expectedType != constants.translator.voidMarker) {
      if (expectedType.nullable) {
        w.HeapType heapType =
            expectedType is w.RefType ? expectedType.heapType : w.HeapType.data;
        b.ref_null(heapType);
      } else {
        // This only happens in invalid but unreachable code produced by the
        // TFA dead-code elimination.
        b.comment("Non-nullable null constant");
        b.block([], [expectedType]);
        b.unreachable();
        b.end();
      }
    }
    return expectedType;
  }

  w.ValueType _maybeBox(w.ValueType wasmType, void Function() pushValue) {
    if (expectedType is w.RefType) {
      ClassInfo info = translator.classInfo[translator.boxedClasses[wasmType]]!;
      b.i32_const(info.classId);
      pushValue();
      translator.struct_new(b, info);
      return info.nonNullableType;
    } else {
      pushValue();
      return wasmType;
    }
  }

  @override
  w.ValueType visitBoolConstant(BoolConstant constant) {
    return _maybeBox(w.NumType.i32, () {
      b.i32_const(constant.value ? 1 : 0);
    });
  }

  @override
  w.ValueType visitIntConstant(IntConstant constant) {
    return _maybeBox(w.NumType.i64, () {
      b.i64_const(constant.value);
    });
  }

  @override
  w.ValueType visitDoubleConstant(DoubleConstant constant) {
    return _maybeBox(w.NumType.f64, () {
      b.f64_const(constant.value);
    });
  }

  @override
  w.ValueType visitStringConstant(StringConstant constant) {
    bool isOneByte = constant.value.codeUnits.every((c) => c <= 255);
    ClassInfo info = translator.classInfo[isOneByte
        ? translator.oneByteStringClass
        : translator.twoByteStringClass]!;
    w.RefType type = info.nonNullableType;
    instantiateLazyConstant(constant, type, (function, b) {
      StringBuffer buffer =
          isOneByte ? constants.oneByteStrings : constants.twoByteStrings;
      int offset = buffer.length;
      int length = constant.value.length;
      buffer.write(constant.value);

      b.i32_const(offset);
      b.i32_const(length);
      b.call(isOneByte
          ? constants.oneByteStringFunction
          : constants.twoByteStringFunction);
    });
    return type;
  }

  @override
  w.ValueType visitInstanceConstant(InstanceConstant constant) {
    Class cls = constant.classNode;
    ClassInfo info = translator.classInfo[cls]!;
    w.RefType type = info.nonNullableType;
    instantiateLazyConstant(constant, type, (function, b) {
      const int baseFieldCount = 2;
      int fieldCount = info.struct.fields.length;
      List<Constant?> subConstants = List.filled(fieldCount, null);
      constant.fieldValues.forEach((reference, subConstant) {
        int index = translator.fieldIndex[reference.asField]!;
        assert(subConstants[index] == null);
        subConstants[index] = subConstant;
      });

      Map<TypeParameter, DartType> substitution = {};
      List<DartType> args = constant.typeArguments;
      while (true) {
        for (int i = 0; i < cls.typeParameters.length; i++) {
          TypeParameter parameter = cls.typeParameters[i];
          DartType arg = substitute(args[i], substitution);
          substitution[parameter] = arg;
          int index = translator.typeParameterIndex[parameter]!;
          subConstants[index] = TypeLiteralConstant(arg);
        }
        Supertype? supertype = cls.supertype;
        if (supertype == null) break;
        cls = supertype.classNode;
        args = supertype.typeArguments;
      }

      b.i32_const(info.classId);
      b.i32_const(initialIdentityHash);
      for (int i = baseFieldCount; i < fieldCount; i++) {
        Constant subConstant = subConstants[i]!;
        constants.instantiateConstant(
            function, b, subConstant, info.struct.fields[i].type.unpacked);
      }
      translator.struct_new(b, info);
    });
    return type;
  }

  @override
  w.ValueType visitListConstant(ListConstant constant) {
    // TODO: Use unmodifiable list
    ClassInfo info = translator.classInfo[translator.fixedLengthListClass]!;
    w.RefType type = info.nonNullableType;
    instantiateLazyConstant(constant, type, (function, b) {
      w.RefType refType = info.struct.fields.last.type.unpacked as w.RefType;
      w.ArrayType arrayType =
          (refType.heapType as w.DefHeapType).def as w.ArrayType;
      w.ValueType elementType = arrayType.elementType.type.unpacked;
      int length = constant.entries.length;
      w.Local arrayLocal = function!.addLocal(
          refType.withNullability(!translator.options.localNullability));
      b.i32_const(info.classId);
      b.i32_const(initialIdentityHash);
      constants.instantiateConstant(
          function,
          b,
          TypeLiteralConstant(constant.typeArgument),
          constants.typeInfo.nullableType);
      b.i64_const(length);
      b.i32_const(length);
      translator.array_new_default(b, arrayType);
      b.local_set(arrayLocal);
      for (int i = 0; i < length; i++) {
        b.local_get(arrayLocal);
        b.i32_const(i);
        constants.instantiateConstant(
            function, b, constant.entries[i], elementType);
        b.array_set(arrayType);
      }
      b.local_get(arrayLocal);
      if (arrayLocal.type.nullable) {
        b.ref_as_non_null();
      }
      translator.struct_new(b, info);
    });
    return type;
  }

  @override
  w.ValueType visitStaticTearOffConstant(StaticTearOffConstant constant) {
    w.DefinedFunction closureFunction =
        translator.getTearOffFunction(constant.targetReference.asProcedure);
    int parameterCount = closureFunction.type.inputs.length - 1;
    w.StructType struct = translator.functionStructType(parameterCount);
    w.RefType type = w.RefType.def(struct, nullable: false);
    instantiateLazyConstant(constant, type, (function, b) {
      w.DefinedGlobal global = translator.makeFunctionRef(closureFunction);
      ClassInfo info = translator.classInfo[translator.functionClass]!;

      b.i32_const(info.classId);
      b.i32_const(initialIdentityHash);
      // TODO: Put dummy context in global variable
      translator.struct_new(b, translator.dummyContext);
      b.global_get(global);
      translator.struct_new(b, parameterCount);
    });
    return type;
  }

  @override
  w.ValueType visitTypeLiteralConstant(TypeLiteralConstant constant) {
    DartType cType = constant.type;
    assert(cType is! TypeParameterType);
    DartType type = cType is DynamicType ||
            cType is VoidType ||
            cType is NeverType ||
            cType is NullType
        ? translator.coreTypes.objectRawType(Nullability.nullable)
        : cType is FunctionType
            ? InterfaceType(translator.functionClass, cType.declaredNullability)
            : cType;
    if (type is! InterfaceType) return defaultConstant(constant);
    ClassInfo info = constants.typeInfo;
    instantiateLazyConstant(constant, info.nonNullableType, (function, b) {
      ClassInfo typeInfo = translator.classInfo[type.classNode]!;
      w.ValueType typeListExpectedType = info.struct.fields[3].type.unpacked;

      b.i32_const(info.classId);
      b.i32_const(initialIdentityHash);
      b.i64_const(typeInfo.classId);
      if (type.typeArguments.isEmpty) {
        b.global_get(constants.emptyTypeList);
      } else {
        ListConstant typeArgs = ListConstant(
            InterfaceType(translator.typeClass, Nullability.nonNullable),
            type.typeArguments.map((t) => TypeLiteralConstant(t)).toList());
        constants.instantiateConstant(
            function, b, typeArgs, typeListExpectedType);
      }
      translator.struct_new(b, info);
    });
    return info.nonNullableType;
  }
}
