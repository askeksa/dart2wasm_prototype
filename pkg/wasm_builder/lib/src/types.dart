// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'serialize.dart';

abstract class StorageType implements Serializable {
  bool isSubtypeOf(StorageType other);

  ValueType get unpacked;

  bool get isPrimitive;

  int get byteSize;
}

abstract class ValueType implements StorageType {
  const ValueType();

  @override
  ValueType get unpacked => this;

  @override
  bool get isPrimitive => false;

  @override
  int get byteSize => throw "Size of non-primitive type $runtimeType";

  bool get nullable => false;

  ValueType withNullability(bool nullable) => this;

  bool get defaultable => true;
}

enum NumTypeKind { i32, i64, f32, f64, v128 }

class NumType extends ValueType {
  final NumTypeKind kind;

  const NumType._(this.kind);

  static const i32 = NumType._(NumTypeKind.i32);
  static const i64 = NumType._(NumTypeKind.i64);
  static const f32 = NumType._(NumTypeKind.f32);
  static const f64 = NumType._(NumTypeKind.f64);
  static const v128 = NumType._(NumTypeKind.v128);

  @override
  bool isSubtypeOf(StorageType other) => this == other;

  @override
  bool get isPrimitive => true;

  @override
  int get byteSize {
    switch (kind) {
      case NumTypeKind.i32:
      case NumTypeKind.f32:
        return 4;
      case NumTypeKind.i64:
      case NumTypeKind.f64:
        return 8;
      case NumTypeKind.v128:
        return 16;
    }
  }

  @override
  void serialize(Serializer s) {
    switch (kind) {
      case NumTypeKind.i32:
        s.writeByte(0x7F);
        break;
      case NumTypeKind.i64:
        s.writeByte(0x7E);
        break;
      case NumTypeKind.f32:
        s.writeByte(0x7D);
        break;
      case NumTypeKind.f64:
        s.writeByte(0x7C);
        break;
      case NumTypeKind.v128:
        s.writeByte(0x7B);
        break;
    }
  }

  @override
  String toString() {
    switch (kind) {
      case NumTypeKind.i32:
        return "i32";
      case NumTypeKind.i64:
        return "i64";
      case NumTypeKind.f32:
        return "f32";
      case NumTypeKind.f64:
        return "f64";
      case NumTypeKind.v128:
        return "v128";
    }
  }
}

class Rtt extends ValueType {
  final DefType defType;
  final int? depth;

  const Rtt(this.defType, [this.depth]);

  @override
  bool get defaultable => false;

  @override
  bool isSubtypeOf(StorageType other) =>
      other is Rtt &&
      defType == other.defType &&
      (other.depth == null || depth == other.depth);

  @override
  void serialize(Serializer s) {
    if (depth != null) {
      s.writeByte(0x69);
      s.writeUnsigned(depth!);
    } else {
      s.writeByte(0x68);
    }
    s.writeSigned(defType.index);
  }

  @override
  String toString() => depth == null ? "rtt $defType" : "rtt $depth $defType";

  @override
  bool operator ==(Object other) =>
      other is Rtt && other.defType == defType && other.depth == depth;

  @override
  int get hashCode => defType.hashCode * (3 + (depth ?? -3) * 2);
}

class RefType extends ValueType {
  final HeapType heapType;
  final bool nullable;

  RefType(this.heapType, {bool? nullable})
      : this.nullable = nullable ??
            heapType.nullableByDefault ??
            (throw "Unspecified nullability");

  const RefType._(this.heapType, this.nullable);

  const RefType.any({bool nullable = AnyHeapType.defaultNullability})
      : this._(HeapType.any, nullable);
  const RefType.eq({bool nullable = EqHeapType.defaultNullability})
      : this._(HeapType.eq, nullable);
  const RefType.func({bool nullable = FuncHeapType.defaultNullability})
      : this._(HeapType.func, nullable);
  const RefType.data({bool nullable = DataHeapType.defaultNullability})
      : this._(HeapType.data, nullable);
  const RefType.i31({bool nullable = I31HeapType.defaultNullability})
      : this._(HeapType.i31, nullable);
  const RefType.extern({bool nullable = ExternHeapType.defaultNullability})
      : this._(HeapType.extern, nullable);
  RefType.def(DefType defType, {required bool nullable})
      : this(defType, nullable: nullable);

  @override
  ValueType withNullability(bool nullable) =>
      nullable == this.nullable ? this : RefType(heapType, nullable: nullable);

  @override
  bool get defaultable => nullable;

  @override
  bool isSubtypeOf(StorageType other) {
    if (other is! RefType) return false;
    if (nullable && !other.nullable) return false;
    return heapType.isSubtypeOf(other.heapType);
  }

  @override
  void serialize(Serializer s) {
    if (nullable != heapType.nullableByDefault) {
      s.writeByte(nullable ? 0x6C : 0x6B);
    }
    s.write(heapType);
  }

  @override
  String toString() {
    if (nullable == heapType.nullableByDefault) return "${heapType}ref";
    return "ref${nullable ? " null " : " "}${heapType}";
  }

  @override
  bool operator ==(Object other) =>
      other is RefType &&
      other.heapType == heapType &&
      other.nullable == nullable;

  @override
  int get hashCode => heapType.hashCode * (nullable ? -1 : 1);
}

abstract class HeapType implements Serializable {
  const HeapType();

  static const any = AnyHeapType._();
  static const eq = EqHeapType._();
  static const func = FuncHeapType._();
  static const data = DataHeapType._();
  static const i31 = I31HeapType._();
  static const extern = ExternHeapType._();

  bool? get nullableByDefault;

  bool isSubtypeOf(HeapType other);

  bool isStructuralSubtypeOf(HeapType other) => isSubtypeOf(other);
}

class AnyHeapType extends HeapType {
  const AnyHeapType._();

  static const defaultNullability = true;

  @override
  bool? get nullableByDefault => defaultNullability;

  @override
  bool isSubtypeOf(HeapType other) => other == HeapType.any;

  @override
  void serialize(Serializer s) => s.writeByte(0x6E);

  @override
  String toString() => "any";
}

class EqHeapType extends HeapType {
  const EqHeapType._();

  static const defaultNullability = true;

  @override
  bool? get nullableByDefault => defaultNullability;

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.eq;

  @override
  void serialize(Serializer s) => s.writeByte(0x6D);

  @override
  String toString() => "eq";
}

class FuncHeapType extends HeapType {
  const FuncHeapType._();

  static const defaultNullability = true;

  @override
  bool? get nullableByDefault => defaultNullability;

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.func;

  @override
  void serialize(Serializer s) => s.writeByte(0x70);

  @override
  String toString() => "func";
}

class DataHeapType extends HeapType {
  const DataHeapType._();

  static const defaultNullability = false;

  @override
  bool? get nullableByDefault => defaultNullability;

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.eq || other == HeapType.data;

  @override
  void serialize(Serializer s) => s.writeByte(0x67);

  @override
  String toString() => "data";
}

class I31HeapType extends HeapType {
  const I31HeapType._();

  static const defaultNullability = false;

  @override
  bool? get nullableByDefault => defaultNullability;

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.eq || other == HeapType.i31;

  @override
  void serialize(Serializer s) => s.writeByte(0x6A);

  @override
  String toString() => "i31";
}

class ExternHeapType extends HeapType {
  const ExternHeapType._();

  static const defaultNullability = true;

  @override
  bool? get nullableByDefault => defaultNullability;

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.extern;

  @override
  void serialize(Serializer s) => s.writeByte(0x6F);

  @override
  String toString() => "extern";
}

abstract class DefType extends HeapType {
  int? _index;
  final HeapType? superType;
  final int depth;

  DefType({this.superType})
      : depth = superType is DefType ? superType.depth + 1 : 0;

  int get index => _index ?? (throw "$runtimeType $this not added to module");
  set index(int i) => _index = i;

  bool get hasSuperType => superType != null;

  @override
  bool? get nullableByDefault => null;

  @override
  bool isSubtypeOf(HeapType other) {
    if (this == other) return true;
    if (hasSuperType) {
      return superType!.isSubtypeOf(other);
    }
    return isStructuralSubtypeOf(other);
  }

  @override
  void serialize(Serializer s) => s.writeSigned(index);

  void serializeDefinition(Serializer s);
}

class FunctionType extends DefType {
  final List<ValueType> inputs;
  final List<ValueType> outputs;

  FunctionType(this.inputs, this.outputs, {HeapType? superType})
      : super(superType: superType);

  @override
  bool isStructuralSubtypeOf(HeapType other) {
    if (other == HeapType.any || other == HeapType.func) return true;
    if (other is! FunctionType) return false;
    if (inputs.length != other.inputs.length) return false;
    if (outputs.length != other.outputs.length) return false;
    for (int i = 0; i < inputs.length; i++) {
      // Inputs are contravariant.
      if (!other.inputs[i].isSubtypeOf(inputs[i])) return false;
    }
    for (int i = 0; i < outputs.length; i++) {
      // Outputs are covariant.
      if (!outputs[i].isSubtypeOf(other.outputs[i])) return false;
    }
    return true;
  }

  @override
  void serializeDefinition(Serializer s) {
    s.writeByte(hasSuperType ? 0x5D : 0x60);
    s.writeList(inputs);
    s.writeList(outputs);
    if (hasSuperType) {
      assert(isStructuralSubtypeOf(superType!));
      s.write(superType!);
    }
  }

  @override
  String toString() => "(${inputs.join(", ")}) -> (${outputs.join(", ")})";
}

abstract class DataType extends DefType {
  final String name;

  DataType(this.name, {HeapType? superType}) : super(superType: superType);

  @override
  String toString() => name;
}

class StructType extends DataType {
  final List<FieldType> fields = [];

  StructType(String name, {Iterable<FieldType>? fields, HeapType? superType})
      : super(name, superType: superType) {
    if (fields != null) this.fields.addAll(fields);
  }

  @override
  bool isStructuralSubtypeOf(HeapType other) {
    if (other == HeapType.any ||
        other == HeapType.eq ||
        other == HeapType.data) {
      return true;
    }
    if (other is! StructType) return false;
    if (fields.length < other.fields.length) return false;
    for (int i = 0; i < other.fields.length; i++) {
      if (!fields[i].isSubtypeOf(other.fields[i])) return false;
    }
    return true;
  }

  @override
  void serializeDefinition(Serializer s) {
    s.writeByte(hasSuperType ? 0x5C : 0x5F);
    s.writeList(fields);
    if (hasSuperType) {
      assert(isStructuralSubtypeOf(superType!));
      s.write(superType!);
    }
  }
}

class ArrayType extends DataType {
  late final FieldType elementType;

  ArrayType(String name, {FieldType? elementType, HeapType? superType})
      : super(name, superType: superType) {
    if (elementType != null) this.elementType = elementType;
  }

  @override
  bool isStructuralSubtypeOf(HeapType other) {
    if (other == HeapType.any ||
        other == HeapType.eq ||
        other == HeapType.data) {
      return true;
    }
    if (other is! ArrayType) return false;
    return elementType.isSubtypeOf(other.elementType);
  }

  @override
  void serializeDefinition(Serializer s) {
    s.writeByte(hasSuperType ? 0x5B : 0x5E);
    s.write(elementType);
    if (hasSuperType) {
      assert(isStructuralSubtypeOf(superType!));
      s.write(superType!);
    }
  }
}

class _WithMutability<T extends StorageType> implements Serializable {
  final T type;
  final bool mutable;

  _WithMutability(this.type, this.mutable);

  @override
  void serialize(Serializer s) {
    s.write(type);
    s.writeByte(mutable ? 0x01 : 0x00);
  }

  @override
  String toString() => "${mutable ? "var " : "const "}$type";
}

class GlobalType extends _WithMutability<ValueType> {
  GlobalType(ValueType type, {bool mutable = true}) : super(type, mutable);
}

class FieldType extends _WithMutability<StorageType> {
  FieldType(StorageType type, {bool mutable = true}) : super(type, mutable);

  FieldType.i8({bool mutable: true}) : this(PackedType.i8, mutable: mutable);
  FieldType.i16({bool mutable: true}) : this(PackedType.i16, mutable: mutable);

  bool isSubtypeOf(FieldType other) {
    if (mutable != other.mutable) return false;
    if (mutable) {
      // Mutable fields are invariant.
      return type == other.type;
    } else {
      // Immutable fields are covariant.
      return type.isSubtypeOf(other.type);
    }
  }
}

enum PackedTypeKind { i8, i16 }

class PackedType implements StorageType {
  final PackedTypeKind kind;

  const PackedType._(this.kind);

  static const i8 = PackedType._(PackedTypeKind.i8);
  static const i16 = PackedType._(PackedTypeKind.i16);

  @override
  ValueType get unpacked => NumType.i32;

  @override
  bool isSubtypeOf(StorageType other) => this == other;

  @override
  bool get isPrimitive => true;

  @override
  int get byteSize {
    switch (kind) {
      case PackedTypeKind.i8:
        return 1;
      case PackedTypeKind.i16:
        return 2;
    }
  }

  @override
  void serialize(Serializer s) {
    switch (kind) {
      case PackedTypeKind.i8:
        s.writeByte(0x7A);
        break;
      case PackedTypeKind.i16:
        s.writeByte(0x79);
        break;
    }
  }

  @override
  String toString() {
    switch (kind) {
      case PackedTypeKind.i8:
        return "i8";
      case PackedTypeKind.i16:
        return "i16";
    }
  }
}
