// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/analysis.dart';
import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/closures.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/constants.dart';
import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/functions.dart';
import 'package:dart2wasm/globals.dart';
import 'package:dart2wasm/param_info.dart';
import 'package:dart2wasm/tearoff_reference.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart'
    show ClassHierarchy, ClassHierarchySubtypes, ClosedWorldClassHierarchy;
import 'package:kernel/core_types.dart';
import 'package:kernel/src/printer.dart';
import 'package:kernel/type_environment.dart';
import 'package:vm/metadata/direct_call.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class TranslatorOptions {
  bool exportAll = false;
  bool inlining = false;
  bool lazyConstants = false;
  bool localNullability = false;
  bool nominalTypes = false;
  bool parameterNullability = true;
  bool polymorphicSpecialization = false;
  bool printKernel = false;
  bool printWasm = false;
  bool runtimeTypes = true;
  bool stringDataSegments = false;
  bool stubBodies = false;
  List<int>? watchPoints = null;

  bool get useRttGlobals => runtimeTypes && !nominalTypes;
}

typedef CodeGenCallback = void Function(w.Instructions);

class Translator {
  final TranslatorOptions options;

  Component component;
  List<Library> libraries;
  CoreTypes coreTypes;
  TypeEnvironment typeEnvironment;
  ClosedWorldClassHierarchy hierarchy;
  late ClassHierarchySubtypes subtypes;

  late final Class wasmTypesBaseClass;
  late final Class wasmArrayBaseClass;
  late final Class wasmAnyRefClass;
  late final Class wasmEqRefClass;
  late final Class wasmDataRefClass;
  late final Class boxedBoolClass;
  late final Class boxedIntClass;
  late final Class boxedDoubleClass;
  late final Class functionClass;
  late final Class listBaseClass;
  late final Class fixedLengthListClass;
  late final Class growableListClass;
  late final Class stringBaseClass;
  late final Class oneByteStringClass;
  late final Class twoByteStringClass;
  late final Class typeClass;
  late final Procedure stringEquals;
  late final Procedure stringInterpolate;
  late final Procedure mapFactory;
  late final Procedure mapPut;
  late final Map<Class, w.StorageType> builtinTypes;
  late final Map<w.ValueType, Class> boxedClasses;

  late final ClassInfoCollector classInfoCollector;
  late final ProgramAnalyzer programAnalyzer;
  late final DispatchTable dispatchTable;
  late final Globals globals;
  late final Constants constants;
  late final FunctionCollector functions;

  List<ClassInfo> classes = [];
  Map<Class, ClassInfo> classInfo = {};
  Map<w.HeapType, ClassInfo> classForHeapType = {};
  Map<Field, int> fieldIndex = {};
  Map<TypeParameter, int> typeParameterIndex = {};
  Map<Reference, ParameterInfo> staticParamInfo = {};
  late Procedure mainFunction;
  late final w.Module m;
  late final w.DefinedFunction initFunction;
  late final w.ValueType voidMarker;
  late final w.StructType dummyContext;

  Map<w.StorageType, w.ArrayType> arrayTypeCache = {};
  Map<int, w.StructType> functionTypeCache = {};
  Map<w.StructType, int> functionTypeParameterCount = {};
  Map<int, w.DefinedGlobal> functionTypeRtt = {};
  Map<w.DefinedFunction, w.DefinedGlobal> functionRefCache = {};
  Map<Procedure, w.DefinedFunction> tearOffFunctionCache = {};

  ClassInfo get topInfo => classes[0];
  ClassInfo get objectInfo => classInfo[coreTypes.objectClass]!;

  Translator(this.component, this.coreTypes, this.typeEnvironment, this.options)
      : libraries = component.libraries,
        hierarchy =
            ClassHierarchy(component, coreTypes) as ClosedWorldClassHierarchy {
    subtypes = hierarchy.computeSubtypesInformation();
    classInfoCollector = ClassInfoCollector(this);
    dispatchTable = DispatchTable(this);
    functions = FunctionCollector(this);

    Library coreLibrary =
        component.libraries.firstWhere((l) => l.name == "dart.core");
    Class lookupCore(String name) {
      return coreLibrary.classes.firstWhere((c) => c.name == name);
    }

    Library wasmLibrary =
        component.libraries.firstWhere((l) => l.name == "dart.wasm");
    Class lookupWasm(String name) {
      return wasmLibrary.classes.firstWhere((c) => c.name == name);
    }

    wasmTypesBaseClass = lookupWasm("_WasmBase");
    wasmArrayBaseClass = lookupWasm("_WasmArray");
    wasmAnyRefClass = lookupWasm("WasmAnyRef");
    wasmEqRefClass = lookupWasm("WasmEqRef");
    wasmDataRefClass = lookupWasm("WasmDataRef");
    boxedBoolClass = lookupCore("_BoxedBool");
    boxedIntClass = lookupCore("_BoxedInt");
    boxedDoubleClass = lookupCore("_BoxedDouble");
    functionClass = lookupCore("_Function");
    fixedLengthListClass = lookupCore("_List");
    listBaseClass = lookupCore("_ListBase");
    growableListClass = lookupCore("_GrowableList");
    stringBaseClass = lookupCore("_StringBase");
    oneByteStringClass = lookupCore("_OneByteString");
    twoByteStringClass = lookupCore("_TwoByteString");
    typeClass = lookupCore("_Type");
    stringEquals =
        stringBaseClass.procedures.firstWhere((p) => p.name.text == "==");
    stringInterpolate = stringBaseClass.procedures
        .firstWhere((p) => p.name.text == "_interpolate");
    mapFactory = lookupCore("Map").procedures.firstWhere(
        (p) => p.kind == ProcedureKind.Factory && p.name.text == "");
    mapPut = component.libraries
        .firstWhere((l) => l.name == "dart.collection")
        .classes
        .firstWhere((c) => c.name == "_CompactLinkedCustomHashMap")
        .superclass! // _HashBase
        .superclass! // _LinkedHashMapMixin<K, V>
        .procedures
        .firstWhere((p) => p.name.text == "[]=");
    builtinTypes = {
      coreTypes.boolClass: w.NumType.i32,
      coreTypes.intClass: w.NumType.i64,
      coreTypes.doubleClass: w.NumType.f64,
      wasmAnyRefClass: w.RefType.any(nullable: false),
      wasmEqRefClass: w.RefType.eq(nullable: false),
      wasmDataRefClass: w.RefType.data(nullable: false),
      boxedBoolClass: w.NumType.i32,
      boxedIntClass: w.NumType.i64,
      boxedDoubleClass: w.NumType.f64,
      lookupWasm("WasmI8"): w.PackedType.i8,
      lookupWasm("WasmI16"): w.PackedType.i16,
      lookupWasm("WasmI32"): w.NumType.i32,
      lookupWasm("WasmI64"): w.NumType.i64,
      lookupWasm("WasmF32"): w.NumType.f32,
      lookupWasm("WasmF64"): w.NumType.f64,
    };
    boxedClasses = {
      w.NumType.i32: boxedBoolClass,
      w.NumType.i64: boxedIntClass,
      w.NumType.f64: boxedDoubleClass,
    };
  }

  w.Module translate() {
    m = w.Module(watchPoints: options.watchPoints);
    voidMarker = w.RefType.def(w.StructType("void"), nullable: true);
    dummyContext = m.addStructType("<context>");

    classInfoCollector.collect();

    functions.collectImportsAndExports();
    mainFunction =
        libraries.first.procedures.firstWhere((p) => p.name.text == "main");
    functions.addExport(mainFunction.reference, "main");

    initFunction = m.addFunction(m.addFunctionType([], []));
    m.startFunction = initFunction;

    globals = Globals(this);
    constants = Constants(this);
    programAnalyzer = ProgramAnalyzer(this);

    component.accept(programAnalyzer);
    dispatchTable.build();

    functions.initExports();
    while (functions.pending.isNotEmpty) {
      Reference reference = functions.pending.removeLast();
      Member member = reference.asMember;
      var function =
          functions.getExistingFunction(reference) as w.DefinedFunction;

      String canonicalName = "$member";
      if (reference.isSetter) {
        canonicalName = "$canonicalName=";
      } else if (reference.isGetter || reference.isTearOffReference) {
        int dot = canonicalName.indexOf('.');
        canonicalName = canonicalName.substring(0, dot + 1) +
            '=' +
            canonicalName.substring(dot + 1);
      }
      canonicalName = member.enclosingLibrary == libraries.first
          ? canonicalName
          : "${member.enclosingLibrary.importUri} $canonicalName";

      String? exportName = functions.exports[reference];

      if (options.printKernel || options.printWasm) {
        if (exportName != null) {
          print("#${function.index}: $canonicalName (exported as $exportName)");
        } else {
          print("#${function.index}: $canonicalName");
        }
        print(member.function
            ?.computeFunctionType(Nullability.nonNullable)
            .toStringInternal());
      }
      if (options.printKernel) {
        if (member is Constructor) {
          Class cls = member.enclosingClass;
          for (Field field in cls.fields) {
            if (field.isInstanceMember && field.initializer != null) {
              print("${field.name}: ${field.initializer}");
            }
          }
          for (Initializer initializer in member.initializers) {
            print(initializer);
          }
        }
        Statement? body = member.function?.body;
        if (body != null) {
          print(body);
        }
        if (!options.printWasm) print("");
      }

      if (exportName != null) {
        m.exportFunction(exportName, function);
      } else if (options.exportAll) {
        m.exportFunction(canonicalName, function);
      }
      var codeGen = CodeGenerator(this, function, reference);
      codeGen.generate();

      if (options.printWasm) {
        print(function.type);
        print(function.body.trace);
      }

      for (Lambda lambda in codeGen.closures.lambdas.values) {
        CodeGenerator(this, lambda.function, reference)
            .generateLambda(lambda, codeGen.closures);
        _printFunction(lambda.function, "$canonicalName (closure)");
      }
    }

    dispatchTable.output();
    constants.finalize();
    initFunction.body.end();

    for (ConstantInfo info in constants.constantInfo.values) {
      w.DefinedFunction? function = info.function;
      if (function != null) {
        _printFunction(function, info.constant);
      } else {
        if (options.printWasm) {
          print("Global #${info.global.index}: ${info.constant}");
          print(info.global.initializer.trace);
        }
      }
    }
    if (options.lazyConstants) {
      _printFunction(constants.oneByteStringFunction, "makeOneByteString");
      _printFunction(constants.twoByteStringFunction, "makeTwoByteString");
    }
    _printFunction(initFunction, "init");

    return m;
  }

  void _printFunction(w.DefinedFunction function, Object name) {
    if (options.printWasm) {
      print("#${function.index}: $name");
      print(function.body.trace);
    }
  }

  Class classForType(DartType type) => type.accept(ClassForType(coreTypes));

  Class upperBound(Class a, Class b) {
    if (hierarchy.isSubclassOf(b, a)) return a;
    if (hierarchy.isSubclassOf(a, b)) return b;
    Set<Class> supers(Class cls) =>
        {for (Class? c = cls.superclass; c != null; c = c.superclass) c};
    Set<Class> aSupers = supers(a);
    assert(!aSupers.contains(b));
    Class c;
    for (c = b.superclass!; !aSupers.contains(c); c = c.superclass!);
    return c;
  }

  w.ValueType translateType(DartType type) {
    w.StorageType wasmType = translateStorageType(type);
    if (wasmType is w.ValueType) return wasmType;
    throw "Non-value types only allowed in arrays and fields";
  }

  bool isWasmType(Class cls) {
    while (cls.superclass != null) {
      cls = cls.superclass!;
      if (cls == wasmTypesBaseClass) return true;
    }
    return false;
  }

  w.StorageType typeForInfo(ClassInfo info, bool nullable) {
    Class? cls = info.cls;
    if (cls != null) {
      w.StorageType? builtin = builtinTypes[cls];
      if (builtin != null) {
        if (!nullable) return builtin;
        if (isWasmType(cls)) {
          if (builtin.isPrimitive) throw "Wasm numeric types can't be nullable";
          return (builtin as w.RefType).withNullability(true);
        }
        Class? boxedClass = boxedClasses[builtin];
        if (boxedClass != null) {
          info = classInfo[boxedClass]!;
        }
      }
    }
    return w.RefType.def(info.repr.struct,
        nullable: !options.parameterNullability || nullable);
  }

  w.StorageType translateStorageType(DartType type) {
    assert(type is! VoidType);
    if (type is InterfaceType) {
      if (type.classNode.superclass == wasmArrayBaseClass) {
        DartType elementType = type.typeArguments.single;
        return w.RefType.def(arrayType(elementType), nullable: false);
      }
      return typeForInfo(
          classInfo[type.classNode]!, type.isPotentiallyNullable);
    }
    if (type is DynamicType) {
      return topInfo.nullableType;
    }
    if (type is NullType) {
      return topInfo.nullableType;
    }
    if (type is NeverType) {
      return topInfo.nullableType;
    }
    if (type is VoidType) {
      return voidMarker;
    }
    if (type is TypeParameterType) {
      return translateStorageType(type.isPotentiallyNullable
          ? type.bound.withDeclaredNullability(type.nullability)
          : type.bound);
    }
    if (type is FutureOrType) {
      return topInfo.nullableType;
    }
    if (type is FunctionType) {
      if (type.requiredParameterCount != type.positionalParameters.length ||
          type.namedParameters.isNotEmpty) {
        throw "Function types with optional parameters not supported: $type";
      }
      return w.RefType.def(functionStructType(type.requiredParameterCount),
          nullable:
              !options.parameterNullability || type.isPotentiallyNullable);
    }
    throw "Unsupported type ${type.runtimeType}";
  }

  w.ArrayType arrayType(DartType type) {
    while (type is TypeParameterType) type = type.bound;
    return wasmArrayType(
        translateStorageType(type), type.toText(defaultAstTextStrategy));
  }

  w.ArrayType wasmArrayType(w.StorageType type, String name) {
    return arrayTypeCache.putIfAbsent(type,
        () => m.addArrayType("Array<$name>")..elementType = w.FieldType(type));
  }

  w.StructType functionStructType(int parameterCount) {
    return functionTypeCache.putIfAbsent(parameterCount, () {
      ClassInfo info = classInfo[functionClass]!;
      w.StructType struct = m.addStructType("Function$parameterCount",
          fields: info.struct.fields,
          superType: options.nominalTypes ? info.struct : null);
      assert(struct.fields.length == FieldIndex.closureFunction);
      struct.fields.add(w.FieldType(
          w.RefType.def(functionType(parameterCount), nullable: false),
          mutable: false));
      if (options.useRttGlobals) {
        functionTypeRtt[parameterCount] =
            classInfoCollector.makeRtt(struct, info);
      }
      functionTypeParameterCount[struct] = parameterCount;
      return struct;
    });
  }

  w.FunctionType functionType(int parameterCount) {
    return m.addFunctionType([
      w.RefType.data(),
      ...List<w.ValueType>.filled(parameterCount, topInfo.nullableType)
    ], [
      topInfo.nullableType
    ]);
  }

  int parameterCountForFunctionStruct(w.HeapType heapType) {
    return functionTypeParameterCount[(heapType as w.DefHeapType).def]!;
  }

  w.DefinedGlobal makeFunctionRef(w.DefinedFunction f) {
    return functionRefCache.putIfAbsent(f, () {
      w.DefinedGlobal global = m.addGlobal(
          w.GlobalType(w.RefType.def(f.type, nullable: false), mutable: false));
      global.initializer.ref_func(f);
      global.initializer.end();
      return global;
    });
  }

  w.DefinedFunction getTearOffFunction(Procedure member) {
    return tearOffFunctionCache.putIfAbsent(member, () {
      assert(member.kind == ProcedureKind.Method);
      FunctionNode functionNode = member.function;
      int parameterCount = functionNode.requiredParameterCount;
      if (functionNode.positionalParameters.length != parameterCount ||
          functionNode.namedParameters.isNotEmpty) {
        throw "Not supported: Tear-off with optional parameters"
            " at ${member.location}";
      }
      if (functionNode.typeParameters.isNotEmpty) {
        throw "Not supported: Tear-off with type parameters"
            " at ${member.location}";
      }
      w.FunctionType memberSignature = signatureFor(member.reference);
      w.FunctionType closureSignature = functionType(parameterCount);
      int signatureOffset = member.isInstanceMember ? 1 : 0;
      assert(memberSignature.inputs.length == signatureOffset + parameterCount);
      assert(closureSignature.inputs.length == 1 + parameterCount);
      w.DefinedFunction function = m.addFunction(closureSignature);
      w.BaseFunction target = functions.getFunction(member.reference);
      w.Instructions b = function.body;
      for (int i = 0; i < memberSignature.inputs.length; i++) {
        w.Local paramLocal = function.locals[(1 - signatureOffset) + i];
        b.local_get(paramLocal);
        convertType(function, paramLocal.type, memberSignature.inputs[i]);
      }
      b.call(target);
      convertType(function, outputOrVoid(target.type.outputs),
          outputOrVoid(closureSignature.outputs));
      b.end();
      return function;
    });
  }

  w.ValueType ensureBoxed(w.ValueType type) {
    // Box receiver if it's primitive
    if (type is w.RefType) return type;
    return w.RefType.def(classInfo[boxedClasses[type]!]!.struct,
        nullable: false);
  }

  w.ValueType typeForLocal(w.ValueType type) {
    return options.localNullability ? type : type.withNullability(true);
  }

  w.ValueType outputOrVoid(List<w.ValueType> outputs) {
    return outputs.isEmpty ? voidMarker : outputs.single;
  }

  bool needsConversion(w.ValueType from, w.ValueType to) {
    return (from == voidMarker) ^ (to == voidMarker) || !from.isSubtypeOf(to);
  }

  void convertType(
      w.DefinedFunction function, w.ValueType from, w.ValueType to) {
    w.Instructions b = function.body;
    if (from == voidMarker || to == voidMarker) {
      if (from != voidMarker) {
        b.drop();
        return;
      }
      if (to != voidMarker) {
        if (to is w.RefType && to.nullable) {
          // This can happen when a void method has its return type overridden to
          // return a value, in which case the selector signature will have a
          // non-void return type to encompass all possible return values.
          b.ref_null(to.heapType);
        } else {
          // This only happens in invalid but unreachable code produced by the
          // TFA dead-code elimination.
          b.comment("Non-nullable void conversion");
          b.unreachable();
        }
        return;
      }
    }
    if (!from.isSubtypeOf(to)) {
      if (from is! w.RefType && to is w.RefType) {
        // Boxing
        ClassInfo info = classInfo[boxedClasses[from]!]!;
        assert(w.HeapType.def(info.struct).isSubtypeOf(to.heapType));
        w.Local temp = function.addLocal(from);
        b.local_set(temp);
        b.i32_const(info.classId);
        b.local_get(temp);
        struct_new(b, info);
      } else if (from is w.RefType && to is! w.RefType) {
        // Unboxing
        ClassInfo info = classInfo[boxedClasses[to]!]!;
        if (!from.heapType.isSubtypeOf(w.HeapType.def(info.struct))) {
          // Cast to box type
          if (!from.heapType.isSubtypeOf(w.HeapType.data)) {
            b.ref_as_data();
          }
          ref_cast(b, info);
        }
        b.struct_get(info.struct, FieldIndex.boxValue);
      } else if (from.withNullability(false).isSubtypeOf(to)) {
        // Null check
        b.ref_as_non_null();
      } else {
        // Downcast
        var heapType = (to as w.RefType).heapType;
        ClassInfo? info = classForHeapType[heapType];
        if (from.nullable && !to.nullable) {
          b.ref_as_non_null();
        }
        if (!(from as w.RefType).heapType.isSubtypeOf(w.HeapType.data)) {
          b.ref_as_data();
        }
        ref_cast(b, info ?? parameterCountForFunctionStruct(heapType));
      }
    }
  }

  w.FunctionType signatureFor(Reference target) {
    Member member = target.asMember;
    if (member.isInstanceMember) {
      return dispatchTable.selectorForTarget(target).signature;
    } else {
      return functions.getFunction(target).type;
    }
  }

  ParameterInfo paramInfoFor(Reference target) {
    Member member = target.asMember;
    if (member.isInstanceMember) {
      return dispatchTable.selectorForTarget(target).paramInfo;
    } else {
      return staticParamInfo.putIfAbsent(
          target, () => ParameterInfo.fromMember(target));
    }
  }

  Member? singleTarget(TreeNode node) {
    DirectCallMetadataRepository metadata =
        component.metadata[DirectCallMetadataRepository.repositoryTag]
            as DirectCallMetadataRepository;
    return metadata.mapping[node]?.target;
  }

  bool shouldInline(Reference target) {
    if (!options.inlining) return false;
    Member member = target.asMember;
    if (member is Field) return true;
    Statement? body = member.function!.body;
    return body != null && NodeCounter().countNodes(body) < 4;
  }

  // Wrappers for object allocation and cast instructions to abstract over
  // RTT-based and static versions of the instructions.
  // The [type] parameter taken by the methods is either a [ClassInfo] (to use
  // the RTT for the class), an [int] (to use the RTT for the closure struct
  // corresponding to functions with that number of parameters) or a
  // [w.DataType] (to use the canonical RTT for the type).

  void struct_new(w.Instructions b, Object type) {
    if (options.runtimeTypes) {
      final struct = _emitRtt(b, type) as w.StructType;
      b.struct_new_with_rtt(struct);
    } else {
      b.struct_new(_targetType(type) as w.StructType);
    }
  }

  void struct_new_default(w.Instructions b, Object type) {
    if (options.runtimeTypes) {
      final struct = _emitRtt(b, type) as w.StructType;
      b.struct_new_default_with_rtt(struct);
    } else {
      b.struct_new_default(_targetType(type) as w.StructType);
    }
  }

  void array_new(w.Instructions b, w.ArrayType type) {
    if (options.runtimeTypes) {
      b.rtt_canon(type);
      b.array_new_with_rtt(type);
    } else {
      b.array_new(type);
    }
  }

  void array_new_default(w.Instructions b, w.ArrayType type) {
    if (options.runtimeTypes) {
      b.rtt_canon(type);
      b.array_new_default_with_rtt(type);
    } else {
      b.array_new_default(type);
    }
  }

  void array_init(w.Instructions b, w.ArrayType type, int length) {
    if (options.runtimeTypes) {
      b.rtt_canon(type);
      b.array_init(type, length);
    } else {
      b.array_init_static(type, length);
    }
  }

  void array_init_from_data(
      w.Instructions b, w.ArrayType type, w.DataSegment data) {
    if (options.runtimeTypes) {
      b.rtt_canon(type);
      b.array_init_from_data(type, data);
    } else {
      b.array_init_from_data_static(type, data);
    }
  }

  void ref_test(w.Instructions b, Object type) {
    if (options.runtimeTypes) {
      _emitRtt(b, type);
      b.ref_test();
    } else {
      b.ref_test_static(_targetType(type));
    }
  }

  void ref_cast(w.Instructions b, Object type) {
    if (options.runtimeTypes) {
      _emitRtt(b, type);
      b.ref_cast();
    } else {
      b.ref_cast_static(_targetType(type));
    }
  }

  void br_on_cast(w.Instructions b, w.Label label, Object type) {
    if (options.runtimeTypes) {
      _emitRtt(b, type);
      b.br_on_cast(label);
    } else {
      b.br_on_cast_static(label, _targetType(type));
    }
  }

  void br_on_cast_fail(w.Instructions b, w.Label label, Object type) {
    if (options.runtimeTypes) {
      _emitRtt(b, type);
      b.br_on_cast_fail(label);
    } else {
      b.br_on_cast_static_fail(label, _targetType(type));
    }
  }

  w.DefType _emitRtt(w.Instructions b, Object type) {
    if (type is ClassInfo) {
      if (options.nominalTypes) {
        b.rtt_canon(type.struct);
      } else {
        b.global_get(type.rtt);
      }
      return type.struct;
    } else if (type is int) {
      int parameterCount = type;
      w.StructType struct = functionStructType(parameterCount);
      if (options.nominalTypes) {
        b.rtt_canon(struct);
      } else {
        w.DefinedGlobal rtt = functionTypeRtt[parameterCount]!;
        b.global_get(rtt);
      }
      return struct;
    } else {
      b.rtt_canon(type as w.DataType);
      return type;
    }
  }

  w.DefType _targetType(Object type) => type is ClassInfo
      ? type.struct
      : type is int
          ? functionStructType(type)
          : type as w.DefType;
}

class NodeCounter extends Visitor<void> with VisitorVoidMixin {
  int count = 0;

  int countNodes(Node node) {
    count = 0;
    node.accept(this);
    return count;
  }

  void defaultNode(Node node) {
    count++;
    node.visitChildren(this);
  }
}

class ClassForType extends DartTypeVisitor<Class> {
  final CoreTypes coreTypes;

  ClassForType(this.coreTypes);

  Class defaultDartType(DartType node) => throw "Unsupported type $node";

  Class visitDynamicType(DynamicType node) => coreTypes.objectClass;
  Class visitVoidType(VoidType node) => coreTypes.objectClass;
  Class visitInterfaceType(InterfaceType node) => node.classNode;
  Class visitFutureOrType(FutureOrType node) => coreTypes.objectClass;
  Class visitFunctionType(FunctionType node) => coreTypes.objectClass; // TODO
  Class visitTypeParameterType(TypeParameterType node) =>
      node.bound.accept(this);
  Class visitNeverType(NeverType node) => coreTypes.objectClass;
  Class visitNullType(NullType node) => coreTypes.objectClass;
}

extension GetterSetterReference on Reference {
  bool get isImplicitGetter {
    Member member = asMember;
    return member is Field && member.getterReference == this;
  }

  bool get isImplicitSetter {
    Member member = asMember;
    return member is Field && member.setterReference == this;
  }

  bool get isGetter {
    Member member = asMember;
    return member is Procedure && member.isGetter || isImplicitGetter;
  }

  bool get isSetter {
    Member member = asMember;
    return member is Procedure && member.isSetter || isImplicitSetter;
  }
}
