// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class Intrinsifier {
  final CodeGenerator codeGen;
  static const w.ValueType boolType = w.NumType.i32;
  static const w.ValueType intType = w.NumType.i64;
  static const w.ValueType doubleType = w.NumType.f64;

  static final Map<w.ValueType, Map<w.ValueType, Map<String, CodeGenCallback>>>
      binaryOperatorMap = {
    intType: {
      intType: {
        '+': (b) => b.i64_add(),
        '-': (b) => b.i64_sub(),
        '*': (b) => b.i64_mul(),
        '~/': (b) => b.i64_div_s(),
        '&': (b) => b.i64_and(),
        '|': (b) => b.i64_or(),
        '^': (b) => b.i64_xor(),
        '<<': (b) => b.i64_shl(),
        '>>': (b) => b.i64_shr_s(),
        '>>>': (b) => b.i64_shr_u(),
        '<': (b) => b.i64_lt_s(),
        '<=': (b) => b.i64_le_s(),
        '>': (b) => b.i64_gt_s(),
        '>=': (b) => b.i64_ge_s(),
      }
    },
    doubleType: {
      doubleType: {
        '+': (b) => b.f64_add(),
        '-': (b) => b.f64_sub(),
        '*': (b) => b.f64_mul(),
        '/': (b) => b.f64_div(),
        '<': (b) => b.f64_lt(),
        '<=': (b) => b.f64_le(),
        '>': (b) => b.f64_gt(),
        '>=': (b) => b.f64_ge(),
      }
    },
  };
  static final Map<w.ValueType, Map<String, CodeGenCallback>> unaryOperatorMap =
      {
    intType: {
      'unary-': (b) {
        b.i64_const(-1);
        b.i64_mul();
      },
      '~': (b) {
        b.i64_const(-1);
        b.i64_xor();
      },
      'toDouble': (b) {
        b.f64_convert_i64_s();
      },
    },
    doubleType: {
      'unary-': (b) {
        b.f64_neg();
      },
      'toInt': (b) {
        b.i64_trunc_sat_f64_s();
      },
      'roundToDouble': (b) {
        b.f64_nearest();
      },
      'floorToDouble': (b) {
        b.f64_floor();
      },
      'ceilToDouble': (b) {
        b.f64_ceil();
      },
      'truncateToDouble': (b) {
        b.f64_trunc();
      },
    },
  };
  static final Map<String, w.ValueType> unaryResultMap = {
    'toDouble': w.NumType.f64,
    'toInt': w.NumType.i64,
    'roundToDouble': w.NumType.f64,
    'floorToDouble': w.NumType.f64,
    'ceilToDouble': w.NumType.f64,
    'truncateToDouble': w.NumType.f64,
  };

  Translator get translator => codeGen.translator;
  w.Instructions get b => codeGen.b;

  DartType dartTypeOf(Expression exp) => codeGen.dartTypeOf(exp);

  w.ValueType typeOfExp(Expression exp) {
    return translator.translateType(dartTypeOf(exp));
  }

  static bool isComparison(String op) =>
      op == '<' || op == '<=' || op == '>' || op == '>=';

  Intrinsifier(this.codeGen);

  w.ValueType? generateInstanceGetterIntrinsic(InstanceGet node) {
    DartType receiverType = dartTypeOf(node.receiver);
    String name = node.name.text;
    if (node.interfaceTarget.enclosingClass == translator.wasmArrayBaseClass) {
      assert(name == 'length');
      DartType elementType =
          (receiverType as InterfaceType).typeArguments.single;
      w.ArrayType arrayType = translator.arrayType(elementType);
      Expression array = node.receiver;
      codeGen.wrap(array, w.RefType.def(arrayType, nullable: true));
      b.array_len(arrayType);
      b.i64_extend_i32_u();
      return w.NumType.i64;
    }
    if (node.interfaceTarget.enclosingClass == translator.coreTypes.intClass &&
        name == 'bitLength') {
      w.Local temp = codeGen.function.addLocal(w.NumType.i64);
      b.i64_const(64);
      codeGen.wrap(node.receiver, w.NumType.i64);
      b.local_tee(temp);
      b.local_get(temp);
      b.i64_const(63);
      b.i64_shr_s();
      b.i64_xor();
      b.i64_clz();
      b.i64_sub();
      return w.NumType.i64;
    }
  }

  w.ValueType? generateInstanceIntrinsic(InstanceInvocation node) {
    Expression receiver = node.receiver;
    DartType receiverType = dartTypeOf(receiver);
    String name = node.name.text;
    if (node.interfaceTarget.enclosingClass?.superclass ==
        translator.wasmArrayBaseClass) {
      DartType elementType =
          (receiverType as InterfaceType).typeArguments.single;
      w.ArrayType arrayType = translator.arrayType(elementType);
      w.StorageType wasmType = arrayType.elementType.type;
      bool innerExtend =
          wasmType == w.PackedType.i8 || wasmType == w.PackedType.i16;
      bool outerExtend =
          wasmType.unpacked == w.NumType.i32 || wasmType == w.NumType.f32;
      switch (name) {
        case 'read':
        case 'readSigned':
        case 'readUnsigned':
          bool unsigned = name == 'readUnsigned';
          Expression array = receiver;
          Expression index = node.arguments.positional.single;
          codeGen.wrap(array, w.RefType.def(arrayType, nullable: true));
          codeGen.wrap(index, w.NumType.i64);
          b.i32_wrap_i64();
          if (innerExtend) {
            if (unsigned) {
              b.array_get_u(arrayType);
            } else {
              b.array_get_s(arrayType);
            }
          } else {
            b.array_get(arrayType);
          }
          if (outerExtend) {
            if (wasmType == w.NumType.f32) {
              b.f64_promote_f32();
              return w.NumType.f64;
            } else {
              if (unsigned) {
                b.i64_extend_i32_u();
              } else {
                b.i64_extend_i32_s();
              }
              return w.NumType.i64;
            }
          }
          return wasmType.unpacked;
        case 'write':
          Expression array = receiver;
          Expression index = node.arguments.positional[0];
          Expression value = node.arguments.positional[1];
          codeGen.wrap(array, w.RefType.def(arrayType, nullable: true));
          codeGen.wrap(index, w.NumType.i64);
          b.i32_wrap_i64();
          codeGen.wrap(value, typeOfExp(value));
          if (outerExtend) {
            if (wasmType == w.NumType.f32) {
              b.f32_demote_f64();
            } else {
              b.i32_wrap_i64();
            }
          }
          b.array_set(arrayType);
          return codeGen.voidMarker;
        default:
          throw "Unsupported array method: $name";
      }
    }

    if (receiver is ConstantExpression &&
        receiver.constant is ListConstant &&
        name == '[]') {
      ClassInfo info = translator.classInfo[translator.listBaseClass]!;
      w.RefType listType = info.nullableType;
      Field arrayField = translator.listBaseClass.fields
          .firstWhere((f) => f.name.text == '_data');
      int arrayFieldIndex = translator.fieldIndex[arrayField]!;
      w.ArrayType arrayType =
          ((info.struct.fields[arrayFieldIndex].type as w.RefType).heapType
                  as w.DefHeapType)
              .def as w.ArrayType;
      codeGen.wrap(receiver, listType);
      b.struct_get(info.struct, arrayFieldIndex);
      codeGen.wrap(node.arguments.positional.single, w.NumType.i64);
      b.i32_wrap_i64();
      b.array_get(arrayType);
      return translator.topInfo.nullableType;
    }

    if (node.arguments.positional.length == 1) {
      // Binary operator
      Expression left = node.receiver;
      Expression right = node.arguments.positional.single;
      DartType argType = dartTypeOf(right);
      if (argType is VoidType) return null;
      w.ValueType leftType = translator.translateType(receiverType);
      w.ValueType rightType = translator.translateType(argType);
      var code = binaryOperatorMap[leftType]?[rightType]?[name];
      if (code != null) {
        w.ValueType outType = isComparison(name) ? w.NumType.i32 : leftType;
        codeGen.wrap(left, leftType);
        codeGen.wrap(right, rightType);
        code(b);
        return outType;
      }
    } else if (node.arguments.positional.length == 0) {
      // Unary operator
      Expression operand = node.receiver;
      w.ValueType opType = translator.translateType(receiverType);
      var code = unaryOperatorMap[opType]?[name];
      if (code != null) {
        codeGen.wrap(operand, opType);
        code(b);
        return unaryResultMap[name] ?? opType;
      }
    }
  }

  w.ValueType? generateEqualsIntrinsic(EqualsCall node) {
    w.ValueType leftType = typeOfExp(node.left);
    w.ValueType rightType = typeOfExp(node.right);

    if (leftType == boolType && rightType == boolType) {
      codeGen.wrap(node.left, w.NumType.i32);
      codeGen.wrap(node.right, w.NumType.i32);
      b.i32_eq();
      return w.NumType.i32;
    }

    if (leftType == intType && rightType == intType) {
      codeGen.wrap(node.left, w.NumType.i64);
      codeGen.wrap(node.right, w.NumType.i64);
      b.i64_eq();
      return w.NumType.i32;
    }

    if (leftType == doubleType && rightType == doubleType) {
      codeGen.wrap(node.left, w.NumType.f64);
      codeGen.wrap(node.right, w.NumType.f64);
      b.f64_eq();
      return w.NumType.i32;
    }
  }

  w.ValueType? generateStaticIntrinsic(StaticInvocation node) {
    if (node.target.enclosingLibrary == translator.coreTypes.coreLibrary) {
      switch (node.name.text) {
        case "identical":
          Expression first = node.arguments.positional[0];
          Expression second = node.arguments.positional[1];
          DartType boolType = translator.coreTypes.boolNonNullableRawType;
          InterfaceType intType = translator.coreTypes.intNonNullableRawType;
          DartType doubleType = translator.coreTypes.doubleNonNullableRawType;
          List<DartType> types = [dartTypeOf(first), dartTypeOf(second)];
          if (types.every((t) => t == intType)) {
            codeGen.wrap(first, w.NumType.i64);
            codeGen.wrap(second, w.NumType.i64);
            b.i64_eq();
            return w.NumType.i32;
          }
          if (types.every((t) =>
              t is InterfaceType &&
              t != boolType &&
              t != doubleType &&
              !translator.hierarchy
                  .isSubtypeOf(intType.classNode, t.classNode))) {
            codeGen.wrap(first, w.RefType.eq(nullable: true));
            codeGen.wrap(second, w.RefType.eq(nullable: true));
            b.ref_eq();
            return w.NumType.i32;
          }
          break;
        case "_getHash":
          Expression arg = node.arguments.positional[0];
          w.ValueType objectType = translator.objectInfo.nullableType;
          codeGen.wrap(arg, objectType);
          b.struct_get(translator.objectInfo.struct, FieldIndex.identityHash);
          b.i64_extend_i32_u();
          return w.NumType.i64;
        case "_setHash":
          Expression arg = node.arguments.positional[0];
          Expression hash = node.arguments.positional[1];
          w.ValueType objectType = translator.objectInfo.nullableType;
          codeGen.wrap(arg, objectType);
          codeGen.wrap(hash, w.NumType.i64);
          b.i32_wrap_i64();
          b.struct_set(translator.objectInfo.struct, FieldIndex.identityHash);
          return codeGen.voidMarker;
      }
    }

    if (node.target.enclosingLibrary.name == "dart._internal") {
      switch (node.name.text) {
        case "unsafeCast":
          w.ValueType targetType =
              translator.translateType(node.arguments.types.single);
          Expression operand = node.arguments.positional.single;
          return codeGen.wrap(operand, targetType);
        case "allocateOneByteString":
          ClassInfo info = translator.classInfo[translator.oneByteStringClass]!;
          w.ArrayType arrayType =
              translator.wasmArrayType(w.PackedType.i8, "WasmI8");
          Expression length = node.arguments.positional[0];
          b.i32_const(info.classId);
          b.i32_const(initialIdentityHash);
          codeGen.wrap(length, w.NumType.i64);
          b.i32_wrap_i64();
          translator.array_new_default(b, arrayType);
          translator.struct_new(b, info);
          return info.nonNullableType;
        case "writeIntoOneByteString":
          ClassInfo info = translator.classInfo[translator.oneByteStringClass]!;
          w.ArrayType arrayType =
              translator.wasmArrayType(w.PackedType.i8, "WasmI8");
          Field arrayField = translator.oneByteStringClass.fields
              .firstWhere((f) => f.name.text == '_array');
          int arrayFieldIndex = translator.fieldIndex[arrayField]!;
          Expression string = node.arguments.positional[0];
          Expression index = node.arguments.positional[1];
          Expression codePoint = node.arguments.positional[2];
          codeGen.wrap(string, info.nonNullableType);
          b.struct_get(info.struct, arrayFieldIndex);
          codeGen.wrap(index, w.NumType.i64);
          b.i32_wrap_i64();
          codeGen.wrap(codePoint, w.NumType.i64);
          b.i32_wrap_i64();
          b.array_set(arrayType);
          return codeGen.voidMarker;
        case "allocateTwoByteString":
          ClassInfo info = translator.classInfo[translator.twoByteStringClass]!;
          w.ArrayType arrayType =
              translator.wasmArrayType(w.PackedType.i16, "WasmI16");
          Expression length = node.arguments.positional[0];
          b.i32_const(info.classId);
          b.i32_const(initialIdentityHash);
          codeGen.wrap(length, w.NumType.i64);
          b.i32_wrap_i64();
          translator.array_new_default(b, arrayType);
          translator.struct_new(b, info);
          return info.nonNullableType;
        case "writeIntoTwoByteString":
          ClassInfo info = translator.classInfo[translator.twoByteStringClass]!;
          w.ArrayType arrayType =
              translator.wasmArrayType(w.PackedType.i16, "WasmI16");
          Field arrayField = translator.oneByteStringClass.fields
              .firstWhere((f) => f.name.text == '_array');
          int arrayFieldIndex = translator.fieldIndex[arrayField]!;
          Expression string = node.arguments.positional[0];
          Expression index = node.arguments.positional[1];
          Expression codePoint = node.arguments.positional[2];
          codeGen.wrap(string, info.nonNullableType);
          b.struct_get(info.struct, arrayFieldIndex);
          codeGen.wrap(index, w.NumType.i64);
          b.i32_wrap_i64();
          codeGen.wrap(codePoint, w.NumType.i64);
          b.i32_wrap_i64();
          b.array_set(arrayType);
          return codeGen.voidMarker;
        case "floatToIntBits":
          codeGen.wrap(node.arguments.positional.single, w.NumType.f64);
          b.f32_demote_f64();
          b.i32_reinterpret_f32();
          b.i64_extend_i32_u();
          return w.NumType.i64;
        case "intBitsToFloat":
          codeGen.wrap(node.arguments.positional.single, w.NumType.i64);
          b.i32_wrap_i64();
          b.f32_reinterpret_i32();
          b.f64_promote_f32();
          return w.NumType.f64;
        case "doubleToIntBits":
          codeGen.wrap(node.arguments.positional.single, w.NumType.f64);
          b.i64_reinterpret_f64();
          return w.NumType.i64;
        case "intBitsToDouble":
          codeGen.wrap(node.arguments.positional.single, w.NumType.i64);
          b.f64_reinterpret_i64();
          return w.NumType.f64;
      }
    }

    if (node.target.enclosingClass?.superclass ==
        translator.wasmArrayBaseClass) {
      Expression length = node.arguments.positional[0];
      w.ArrayType arrayType = translator.arrayType(node.arguments.types.single);
      codeGen.wrap(length, w.NumType.i64);
      b.i32_wrap_i64();
      translator.array_new_default(b, arrayType);
      return w.RefType.def(arrayType, nullable: false);
    }
  }

  bool generateMemberIntrinsic(Reference target, w.DefinedFunction function,
      List<w.Local> paramLocals, w.Label? returnLabel) {
    Member member = target.asMember;
    if (member is! Procedure) return false;
    FunctionNode functionNode = member.function;

    // Object.==
    if (member == translator.coreTypes.objectEquals) {
      b.local_get(paramLocals[0]);
      b.local_get(paramLocals[1]);
      b.ref_eq();
      return true;
    }

    // Object.runtimeType
    if (member.enclosingClass == translator.coreTypes.objectClass &&
        member.name.text == "runtimeType") {
      w.Local receiver = paramLocals[0];
      ClassInfo info = translator.classInfo[translator.typeClass]!;
      w.ValueType typeListExpectedType = info.struct.fields[3].type.unpacked;

      b.i32_const(info.classId);
      b.i32_const(initialIdentityHash);
      b.local_get(receiver);
      b.struct_get(translator.topInfo.struct, FieldIndex.classId);
      b.i64_extend_i32_u();
      // TODO: Type arguments
      b.global_get(translator.constants.emptyTypeList);
      translator.convertType(function,
          translator.constants.emptyTypeList.type.type, typeListExpectedType);
      translator.struct_new(b, info);

      return true;
    }

    // identical
    if (member == translator.coreTypes.identicalProcedure) {
      w.Local first = paramLocals[0];
      w.Local second = paramLocals[1];
      ClassInfo boolInfo = translator.classInfo[translator.boxedBoolClass]!;
      ClassInfo intInfo = translator.classInfo[translator.boxedIntClass]!;
      ClassInfo doubleInfo = translator.classInfo[translator.boxedDoubleClass]!;
      w.Local cid = function.addLocal(w.NumType.i32);
      w.Label ref_eq = b.block();
      b.local_get(first);
      b.br_on_null(ref_eq);
      b.struct_get(translator.topInfo.struct, FieldIndex.classId);
      b.local_tee(cid);

      // Both bool?
      b.i32_const(boolInfo.classId);
      b.i32_eq();
      b.if_();
      b.local_get(first);
      translator.ref_cast(b, boolInfo);
      b.struct_get(boolInfo.struct, FieldIndex.boxValue);
      w.Label bothBool = b.block(const [], [boolInfo.nullableType]);
      b.local_get(second);
      translator.br_on_cast(b, bothBool, boolInfo);
      b.i32_const(0);
      b.return_();
      b.end();
      b.struct_get(boolInfo.struct, FieldIndex.boxValue);
      b.i32_eq();
      b.return_();
      b.end();

      // Both int?
      b.local_get(cid);
      b.i32_const(intInfo.classId);
      b.i32_eq();
      b.if_();
      b.local_get(first);
      translator.ref_cast(b, intInfo);
      b.struct_get(intInfo.struct, FieldIndex.boxValue);
      w.Label bothInt = b.block(const [], [intInfo.nullableType]);
      b.local_get(second);
      translator.br_on_cast(b, bothInt, intInfo);
      b.i32_const(0);
      b.return_();
      b.end();
      b.struct_get(intInfo.struct, FieldIndex.boxValue);
      b.i64_eq();
      b.return_();
      b.end();

      // Both double?
      b.local_get(cid);
      b.i32_const(doubleInfo.classId);
      b.i32_eq();
      b.if_();
      b.local_get(first);
      translator.ref_cast(b, doubleInfo);
      b.struct_get(doubleInfo.struct, FieldIndex.boxValue);
      b.i64_reinterpret_f64();
      w.Label bothDouble = b.block(const [], [doubleInfo.nullableType]);
      b.local_get(second);
      translator.br_on_cast(b, bothDouble, doubleInfo);
      b.i32_const(0);
      b.return_();
      b.end();
      b.struct_get(doubleInfo.struct, FieldIndex.boxValue);
      b.i64_reinterpret_f64();
      b.i64_eq();
      b.return_();
      b.end();

      // Compare as references
      b.end();
      b.local_get(first);
      b.local_get(second);
      b.ref_eq();

      return true;
    }

    if (member.enclosingLibrary.name == "dart._internal") {
      switch (member.name.text) {
        case "ensureTwoByteString":
          ClassInfo oneByteInfo =
              translator.classInfo[translator.oneByteStringClass]!;
          ClassInfo twoByteInfo =
              translator.classInfo[translator.twoByteStringClass]!;
          w.Local inString = paramLocals[0];

          // If the string is already a TwoByteString, just return it.
          b.local_get(inString);
          b.struct_get(translator.topInfo.struct, FieldIndex.classId);
          b.i32_const(twoByteInfo.classId);
          b.i32_eq();
          b.if_();
          b.local_get(inString);
          b.return_();
          b.end();

          // Locals for arrays, index and length
          w.RefType oneByteType = oneByteInfo
              .struct.fields[FieldIndex.stringArray].type.unpacked as w.RefType;
          w.RefType twoByteType = twoByteInfo
              .struct.fields[FieldIndex.stringArray].type.unpacked as w.RefType;
          w.ArrayType oneByteArrayType =
              (oneByteType.heapType as w.DefHeapType).def as w.ArrayType;
          w.ArrayType twoByteArrayType =
              (twoByteType.heapType as w.DefHeapType).def as w.ArrayType;
          w.Local oneByteArray = codeGen.addLocal(oneByteType);
          w.Local twoByteArray = codeGen.addLocal(twoByteType);
          w.Local index = codeGen.addLocal(w.NumType.i32);
          w.Local length = codeGen.addLocal(w.NumType.i32);

          // Get input array and create array for TwoByteString.
          b.local_get(inString);
          translator.ref_cast(b, oneByteInfo);
          b.struct_get(oneByteInfo.struct, FieldIndex.stringArray);
          b.local_tee(oneByteArray);
          b.array_len(oneByteArrayType);
          b.local_tee(length);
          translator.array_new_default(b, twoByteArrayType);
          b.local_set(twoByteArray);

          // Copy contents of string.
          b.i32_const(0);
          b.local_set(index);
          w.Label block = b.block();
          w.Label loop = b.loop();
          b.local_get(index);
          b.local_get(length);
          b.i32_eq();
          b.br_if(block);
          b.local_get(twoByteArray);
          b.local_get(index);
          b.local_get(oneByteArray);
          b.local_get(index);
          b.array_get_u(oneByteArrayType);
          b.array_set(twoByteArrayType);
          b.local_get(index);
          b.i32_const(1);
          b.i32_add();
          b.local_set(index);
          b.br(loop);
          b.end(); // loop
          b.end(); // block

          // Create TwoByteString object
          b.i32_const(twoByteInfo.classId);
          b.i32_const(initialIdentityHash);
          b.local_get(twoByteArray);
          translator.struct_new(b, twoByteInfo.struct);
          return true;
      }
    }

    // int members
    if (member.enclosingClass == translator.boxedIntClass &&
        member.function.body == null) {
      String op = member.name.text;
      if (functionNode.requiredParameterCount == 0) {
        CodeGenCallback? code = unaryOperatorMap[intType]![op];
        if (code != null) {
          w.ValueType resultType = unaryResultMap[op] ?? intType;
          w.ValueType inputType = function.type.inputs.single;
          w.ValueType outputType = function.type.outputs.single;
          b.local_get(function.locals[0]);
          translator.convertType(function, inputType, intType);
          code(b);
          translator.convertType(function, resultType, outputType);
          return true;
        }
      } else if (functionNode.requiredParameterCount == 1) {
        CodeGenCallback? code = binaryOperatorMap[intType]![intType]![op];
        if (code != null) {
          w.ValueType leftType = function.type.inputs[0];
          w.ValueType rightType = function.type.inputs[1];
          w.ValueType outputType = function.type.outputs.single;
          if (rightType == intType) {
            // int parameter
            b.local_get(function.locals[0]);
            translator.convertType(function, leftType, intType);
            b.local_get(function.locals[1]);
            code(b);
            if (!isComparison(op)) {
              translator.convertType(function, intType, outputType);
            }
            return true;
          }
          // num parameter
          ClassInfo intInfo = translator.classInfo[translator.boxedIntClass]!;
          w.Label intArg = b.block(const [], [intInfo.nonNullableType]);
          b.local_get(function.locals[1]);
          translator.br_on_cast(b, intArg, intInfo);
          // double argument
          b.drop();
          b.local_get(function.locals[0]);
          translator.convertType(function, leftType, intType);
          b.f64_convert_i64_s();
          b.local_get(function.locals[1]);
          translator.convertType(function, rightType, doubleType);
          // Inline double op
          CodeGenCallback doubleCode =
              binaryOperatorMap[doubleType]![doubleType]![op]!;
          doubleCode(b);
          if (!isComparison(op)) {
            translator.convertType(function, doubleType, outputType);
          }
          b.return_();
          b.end();
          // int argument
          translator.convertType(function, intInfo.nonNullableType, intType);
          w.Local rightTemp = function.addLocal(intType);
          b.local_set(rightTemp);
          b.local_get(function.locals[0]);
          translator.convertType(function, leftType, intType);
          b.local_get(rightTemp);
          code(b);
          if (!isComparison(op)) {
            translator.convertType(function, intType, outputType);
          }
          return true;
        }
      }
    }

    // double unary members
    if (member.enclosingClass == translator.boxedDoubleClass &&
        member.function.body == null) {
      String op = member.name.text;
      if (functionNode.requiredParameterCount == 0) {
        CodeGenCallback? code = unaryOperatorMap[doubleType]![op];
        if (code != null) {
          w.ValueType resultType = unaryResultMap[op] ?? doubleType;
          w.ValueType inputType = function.type.inputs.single;
          w.ValueType outputType = function.type.outputs.single;
          b.local_get(function.locals[0]);
          translator.convertType(function, inputType, doubleType);
          code(b);
          translator.convertType(function, resultType, outputType);
          return true;
        }
      }
    }

    return false;
  }
}
