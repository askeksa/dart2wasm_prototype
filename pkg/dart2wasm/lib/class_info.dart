// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math';

import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

/// Wasm struct field indices for fields that are accessed explicitly from Wasm
/// code, e.g. in intrinsics.
///
/// The values are validated by asserts, typically either through
/// [ClassInfo.addField] (for manually added fields) or by a line in
/// [FieldIndex.validate] (for fields declared in Dart code).
class FieldIndex {
  static const classId = 0;
  static const boxValue = 1;
  static const identityHash = 1;
  static const stringArray = 2;
  static const closureContext = 2;
  static const closureFunction = 3;

  static void validate(Translator translator) {
    void check(Class cls, String name, int expectedIndex) {
      assert(
          translator.fieldIndex[
                  cls.fields.firstWhere((f) => f.name.text == name)] ==
              expectedIndex,
          "Unexpected field index for ${cls.name}.$name");
    }

    check(translator.boxedBoolClass, "value", FieldIndex.boxValue);
    check(translator.boxedIntClass, "value", FieldIndex.boxValue);
    check(translator.boxedDoubleClass, "value", FieldIndex.boxValue);
    check(translator.oneByteStringClass, "_array", FieldIndex.stringArray);
    check(translator.twoByteStringClass, "_array", FieldIndex.stringArray);
    check(translator.functionClass, "context", FieldIndex.closureContext);
  }
}

const int initialIdentityHash = 0;

class ClassInfo {
  final Class? cls;
  final int classId;
  final int depth;
  final w.StructType struct;
  late final w.DefinedGlobal rtt;
  final ClassInfo? superInfo;
  final Map<TypeParameter, TypeParameter> typeParameterMatch;
  late ClassInfo repr;
  final List<ClassInfo> implementedBy = [];

  late final w.RefType nullableType = w.RefType.def(struct, nullable: true);
  late final w.RefType nonNullableType = w.RefType.def(struct, nullable: false);

  w.RefType typeWithNullability(bool nullable) =>
      nullable ? nullableType : nonNullableType;

  ClassInfo(this.cls, this.classId, this.depth, this.struct, this.superInfo,
      ClassInfoCollector collector,
      {this.typeParameterMatch = const {}}) {
    if (collector.options.useRttGlobals) {
      rtt = collector.makeRtt(struct, superInfo);
    }
    implementedBy.add(this);
  }

  void addField(w.FieldType fieldType, [int? expectedIndex]) {
    assert(expectedIndex == null || expectedIndex == struct.fields.length);
    struct.fields.add(fieldType);
  }
}

ClassInfo upperBound(Iterable<ClassInfo> classes) {
  while (classes.length > 1) {
    Set<ClassInfo> newClasses = {};
    int minDepth = 999999999;
    int maxDepth = 0;
    for (ClassInfo info in classes) {
      minDepth = min(minDepth, info.depth);
      maxDepth = max(maxDepth, info.depth);
    }
    int targetDepth = minDepth == maxDepth ? minDepth - 1 : minDepth;
    for (ClassInfo info in classes) {
      while (info.depth > targetDepth) {
        info = info.superInfo!;
      }
      newClasses.add(info);
    }
    classes = newClasses;
  }
  return classes.single;
}

class ClassInfoCollector {
  final Translator translator;
  int nextClassId = 0;
  late final ClassInfo topInfo;

  late final w.FieldType typeType =
      w.FieldType(translator.classInfo[translator.typeClass]!.nullableType);

  ClassInfoCollector(this.translator);

  w.Module get m => translator.m;

  TranslatorOptions get options => translator.options;

  w.DefinedGlobal makeRtt(w.StructType struct, ClassInfo? superInfo) {
    assert(options.useRttGlobals);
    int depth = superInfo != null ? superInfo.depth + 1 : 0;
    final w.DefinedGlobal rtt =
        m.addGlobal(w.GlobalType(w.Rtt(struct, depth), mutable: false));
    final w.Instructions b = rtt.initializer;
    if (superInfo != null) {
      b.global_get(superInfo.rtt);
      b.rtt_sub(struct);
    } else {
      b.rtt_canon(struct);
    }
    b.end();
    return rtt;
  }

  void initializeTop() {
    final w.StructType struct = translator.structType("#Top");
    topInfo = ClassInfo(null, nextClassId++, 0, struct, null, this);
    translator.classes.add(topInfo);
    translator.classForHeapType[struct] = topInfo;
  }

  void initialize(Class cls) {
    ClassInfo? info = translator.classInfo[cls];
    if (info == null) {
      Class? superclass = cls.superclass;
      if (superclass == null) {
        ClassInfo superInfo = topInfo;
        final w.StructType struct =
            translator.structType(cls.name, superType: superInfo.struct);
        info = ClassInfo(
            cls, nextClassId++, superInfo.depth + 1, struct, superInfo, this);
        // Mark Top type as implementing Object to force the representation
        // type of Object to be Top.
        info.implementedBy.add(topInfo);
      } else {
        initialize(superclass);
        for (Supertype interface in cls.implementedTypes) {
          initialize(interface.classNode);
        }
        // In the Wasm type hierarchy, Object, bool and num sit directly below
        // the Top type. The implementation classes (_StringBase, _Type and the
        // box classes) sit directly below the public classes they implement.
        // All other classes sit below their superclass.
        ClassInfo superInfo = cls == translator.coreTypes.boolClass ||
                cls == translator.coreTypes.numClass
            ? topInfo
            : cls == translator.stringBaseClass ||
                    cls == translator.typeClass ||
                    translator.boxedClasses.values.contains(cls)
                ? translator.classInfo[cls.implementedTypes.single.classNode]!
                : translator.classInfo[superclass]!;
        Map<TypeParameter, TypeParameter> typeParameterMatch = {};
        if (cls.typeParameters.isNotEmpty) {
          Supertype supertype = cls.superclass == superInfo.cls
              ? cls.supertype!
              : cls.implementedTypes.single;
          for (TypeParameter parameter in cls.typeParameters) {
            for (int i = 0; i < supertype.typeArguments.length; i++) {
              DartType arg = supertype.typeArguments[i];
              if (arg is TypeParameterType && arg.parameter == parameter) {
                typeParameterMatch[parameter] =
                    superInfo.cls!.typeParameters[i];
                break;
              }
            }
          }
        }
        bool canReuseSuperStruct =
            typeParameterMatch.length == cls.typeParameters.length &&
                cls.fields.where((f) => f.isInstanceMember).isEmpty;
        w.StructType struct = canReuseSuperStruct
            ? superInfo.struct
            : translator.structType(cls.name, superType: superInfo.struct);
        info = ClassInfo(
            cls, nextClassId++, superInfo.depth + 1, struct, superInfo, this,
            typeParameterMatch: typeParameterMatch);
        for (Supertype interface in cls.implementedTypes) {
          ClassInfo? interfaceInfo = translator.classInfo[interface.classNode];
          while (interfaceInfo != null) {
            interfaceInfo.implementedBy.add(info);
            interfaceInfo = interfaceInfo.superInfo;
          }
        }
      }
      translator.classes.add(info);
      translator.classInfo[cls] = info;
      translator.classForHeapType.putIfAbsent(info.struct, () => info!);
    }
  }

  void computeRepresentation(ClassInfo info) {
    info.repr = upperBound(info.implementedBy);
  }

  void generateFields(ClassInfo info) {
    ClassInfo? superInfo = info.superInfo;
    if (superInfo == null) {
      // Top - add class id field
      info.addField(w.FieldType(w.NumType.i32), FieldIndex.classId);
    } else if (info.struct != superInfo.struct) {
      // Copy fields from superclass
      for (w.FieldType fieldType in superInfo.struct.fields) {
        info.addField(fieldType);
      }
      if (info.cls!.superclass == null) {
        // Object - add identity hash code field
        info.addField(w.FieldType(w.NumType.i32), FieldIndex.identityHash);
      }
      // Add fields for type variables
      for (TypeParameter parameter in info.cls!.typeParameters) {
        TypeParameter? match = info.typeParameterMatch[parameter];
        if (match != null) {
          // Reuse supertype type variable
          translator.typeParameterIndex[parameter] =
              translator.typeParameterIndex[match]!;
        } else {
          translator.typeParameterIndex[parameter] = info.struct.fields.length;
          info.addField(typeType);
        }
      }
      // Add fields for Dart instance fields
      for (Field field in info.cls!.fields) {
        if (field.isInstanceMember) {
          w.ValueType wasmType = translator.translateType(field.type);
          // TODO(askesc): Generalize this check for finer nullability control
          if (wasmType != w.RefType.data()) {
            wasmType = wasmType.withNullability(true);
          }
          translator.fieldIndex[field] = info.struct.fields.length;
          info.addField(w.FieldType(wasmType));
        }
      }
    } else {
      for (TypeParameter parameter in info.cls!.typeParameters) {
        // Reuse supertype type variable
        translator.typeParameterIndex[parameter] =
            translator.typeParameterIndex[info.typeParameterMatch[parameter]]!;
      }
    }
  }

  void collect() {
    // Create class info and Wasm structs for all classes.
    initializeTop();
    for (Library library in translator.component.libraries) {
      for (Class cls in library.classes) {
        initialize(cls);
      }
    }

    // For each class, compute which Wasm struct should be used for the type of
    // variables bearing that class as their Dart type. This is the struct
    // corresponding to the least common supertype of all Dart classes
    // implementing this class.
    for (ClassInfo info in translator.classes) {
      computeRepresentation(info);
    }

    // Now that the representation types for all classes have been computed,
    // fill in the types of the fields in the generated Wasm structs.
    for (ClassInfo info in translator.classes) {
      generateFields(info);
    }

    // Validate that all internally used fields have the expected indices.
    FieldIndex.validate(translator);
  }
}
