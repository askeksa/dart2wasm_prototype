// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'instructions.dart';
import 'serialize.dart';
import 'types.dart';

class Module with SerializerMixin {
  final List<int>? watchPoints;

  final Map<_FunctionTypeKey, FunctionType> functionTypeMap = {};

  final List<DefType> defTypes = [];
  final List<BaseFunction> functions = [];
  final List<Table> tables = [];
  final List<Memory> memories = [];
  final List<DataSegment> dataSegments = [];
  final List<Global> globals = [];
  final List<Export> exports = [];
  BaseFunction? startFunction = null;

  bool anyFunctionsDefined = false;
  bool anyGlobalsDefined = false;
  bool dataReferencedFromGlobalInitializer = false;

  Module({this.watchPoints}) {
    if (watchPoints != null) {
      SerializerMixin.traceEnabled = true;
    }
  }

  Iterable<Import> get imports =>
      functions.whereType<Import>().followedBy(globals.whereType<Import>());

  Iterable<DefinedFunction> get definedFunctions =>
      functions.whereType<DefinedFunction>();

  FunctionType addFunctionType(
      Iterable<ValueType> inputs, Iterable<ValueType> outputs,
      {HeapType? superType}) {
    final List<ValueType> inputList = List.unmodifiable(inputs);
    final List<ValueType> outputList = List.unmodifiable(outputs);
    final _FunctionTypeKey key = _FunctionTypeKey(inputList, outputList);
    return functionTypeMap.putIfAbsent(key, () {
      final type = FunctionType(inputList, outputList, superType: superType)
        ..index = defTypes.length;
      defTypes.add(type);
      return type;
    });
  }

  StructType addStructType(String name,
      {Iterable<FieldType>? fields, HeapType? superType}) {
    final type = StructType(name, fields: fields, superType: superType)
      ..index = defTypes.length;
    defTypes.add(type);
    return type;
  }

  ArrayType addArrayType(String name,
      {FieldType? elementType, HeapType? superType}) {
    final type = ArrayType(name, elementType: elementType, superType: superType)
      ..index = defTypes.length;
    defTypes.add(type);
    return type;
  }

  DefinedFunction addFunction(FunctionType type) {
    anyFunctionsDefined = true;
    final function = DefinedFunction(this, functions.length, type);
    functions.add(function);
    return function;
  }

  Table addTable(int minSize, [int? maxSize]) {
    final table = Table(tables.length, minSize, maxSize);
    tables.add(table);
    return table;
  }

  Memory addMemory(int minSize, [int? maxSize]) {
    final memory = Memory(memories.length, minSize, maxSize);
    memories.add(memory);
    return memory;
  }

  DataSegment addDataSegment(
      [Uint8List? initialContent, Memory? memory, int? offset]) {
    initialContent ??= Uint8List(0);
    assert((memory != null) == (offset != null));
    assert(memory == null ||
        offset! >= 0 && offset + initialContent.length <= memory.minSize);
    final DataSegment data =
        DataSegment(dataSegments.length, initialContent, memory, offset);
    dataSegments.add(data);
    return data;
  }

  DefinedGlobal addGlobal(GlobalType type) {
    anyGlobalsDefined = true;
    final global = DefinedGlobal(this, globals.length, type);
    globals.add(global);
    return global;
  }

  ImportedFunction importFunction(
      String module, String name, FunctionType type) {
    if (anyFunctionsDefined) {
      throw "All function imports must be specified before any definitions.";
    }
    final function = ImportedFunction(module, name, functions.length, type);
    functions.add(function);
    return function;
  }

  ImportedGlobal importGlobal(String module, String name, GlobalType type) {
    if (anyGlobalsDefined) {
      throw "All global imports must be specified before any definitions.";
    }
    final global = ImportedGlobal(module, name, functions.length, type);
    globals.add(global);
    return global;
  }

  void _addExport(Export export) {
    assert(!exports.any((e) => e.name == export.name), export.name);
    exports.add(export);
  }

  void exportFunction(String name, BaseFunction function) {
    function.exportedName = name;
    _addExport(FunctionExport(name, function));
  }

  void exportGlobal(String name, Global global) {
    exports.add(GlobalExport(name, global));
  }

  Uint8List encode() {
    // Wasm module preamble: magic number, version 1.
    writeBytes(const [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]);
    TypeSection(this).serialize(this);
    ImportSection(this).serialize(this);
    FunctionSection(this).serialize(this);
    TableSection(this).serialize(this);
    MemorySection(this).serialize(this);
    if (dataReferencedFromGlobalInitializer) {
      DataCountSection(this).serialize(this);
    }
    GlobalSection(this).serialize(this);
    ExportSection(this).serialize(this);
    StartSection(this).serialize(this);
    ElementSection(this).serialize(this);
    if (!dataReferencedFromGlobalInitializer) {
      DataCountSection(this).serialize(this);
    }
    CodeSection(this).serialize(this);
    DataSection(this).serialize(this);
    return data;
  }
}

class _FunctionTypeKey {
  final List<ValueType> inputs;
  final List<ValueType> outputs;

  _FunctionTypeKey(this.inputs, this.outputs);

  @override
  bool operator ==(Object other) {
    if (other is! _FunctionTypeKey) return false;
    if (inputs.length != other.inputs.length) return false;
    if (outputs.length != other.outputs.length) return false;
    for (int i = 0; i < inputs.length; i++) {
      if (inputs[i] != other.inputs[i]) return false;
    }
    for (int i = 0; i < outputs.length; i++) {
      if (outputs[i] != other.outputs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    int inputHash = 13;
    for (var input in inputs) {
      inputHash = inputHash * 17 + input.hashCode;
    }
    int outputHash = 23;
    for (var output in outputs) {
      outputHash = outputHash * 29 + output.hashCode;
    }
    return (inputHash * 2 + 1) * (outputHash * 2 + 1);
  }
}

abstract class BaseFunction {
  final int index;
  final FunctionType type;
  String? exportedName;

  BaseFunction(this.index, this.type);
}

class DefinedFunction extends BaseFunction
    with SerializerMixin
    implements Serializable {
  final List<Local> locals = [];
  late final Instructions body;

  DefinedFunction(Module module, int index, FunctionType type)
      : super(index, type) {
    for (ValueType paramType in type.inputs) {
      addLocal(paramType);
    }
    body = Instructions(module, type.outputs, locals: locals);
  }

  Local addLocal(ValueType type) {
    Local local = Local(locals.length, type);
    locals.add(local);
    return local;
  }

  @override
  void serialize(Serializer s) {
    // Serialize locals internally first in order to compute the total size of
    // the serialized data.
    int paramCount = type.inputs.length;
    int entries = 0;
    for (int i = paramCount + 1; i <= locals.length; i++) {
      if (i == locals.length || locals[i - 1].type != locals[i].type) entries++;
    }
    writeUnsigned(entries);
    int start = paramCount;
    for (int i = paramCount + 1; i <= locals.length; i++) {
      if (i == locals.length || locals[i - 1].type != locals[i].type) {
        writeUnsigned(i - start);
        write(locals[i - 1].type);
        start = i;
      }
    }

    // Bundle locals and body
    assert(body.isComplete);
    s.writeUnsigned(data.length + body.data.length);
    s.writeData(this);
    s.writeData(body);
  }

  @override
  String toString() => exportedName ?? "#$index";
}

class Local {
  final int index;
  final ValueType type;

  Local(this.index, this.type);

  @override
  String toString() => "$index";
}

class Table implements Serializable {
  final int index;
  final int minSize;
  final int? maxSize;
  final List<BaseFunction?> elements;

  Table(this.index, this.minSize, this.maxSize)
      : elements = List.filled(minSize, null);

  void setElement(int index, BaseFunction function) {
    elements[index] = function;
  }

  @override
  void serialize(Serializer s) {
    s.writeByte(0x70); // funcref
    if (maxSize == null) {
      s.writeByte(0x00);
      s.writeUnsigned(minSize);
    } else {
      s.writeByte(0x01);
      s.writeUnsigned(minSize);
      s.writeUnsigned(maxSize!);
    }
  }
}

class Memory implements Serializable {
  final int index;
  final int minSize;
  final int? maxSize;

  Memory(this.index, this.minSize, [this.maxSize]);

  @override
  void serialize(Serializer s) {
    if (maxSize == null) {
      s.writeByte(0x00);
      s.writeUnsigned(minSize);
    } else {
      s.writeByte(0x01);
      s.writeUnsigned(minSize);
      s.writeUnsigned(maxSize!);
    }
  }
}

class DataSegment implements Serializable {
  final int index;
  final BytesBuilder content;
  final Memory? memory;
  final int? offset;

  DataSegment(this.index, Uint8List initialContent, this.memory, this.offset)
      : content = BytesBuilder()..add(initialContent);

  bool get isActive => memory != null;
  bool get isPassive => memory == null;

  int get length => content.length;

  void append(Uint8List data) {
    content.add(data);
    assert(isPassive ||
        offset! >= 0 && offset! + content.length <= memory!.minSize);
  }

  @override
  void serialize(Serializer s) {
    if (memory != null) {
      // Active segment
      if (memory!.index == 0) {
        s.writeByte(0x00);
      } else {
        s.writeByte(0x02);
        s.writeUnsigned(memory!.index);
      }
      s.writeByte(0x41); // i32.const
      s.writeSigned(offset!);
      s.writeByte(0x0B); // end
    } else {
      // Passive segment
      s.writeByte(0x01);
    }
    s.writeUnsigned(content.length);
    s.writeBytes(content.toBytes());
  }
}

abstract class Global {
  final int index;
  final GlobalType type;

  Global(this.index, this.type);

  @override
  String toString() => "$index";
}

class DefinedGlobal extends Global implements Serializable {
  final Instructions initializer;

  DefinedGlobal(Module module, int index, GlobalType type)
      : initializer =
            Instructions(module, [type.type], isGlobalInitializer: true),
        super(index, type);

  @override
  void serialize(Serializer s) {
    assert(initializer.isComplete);
    s.write(type);
    s.writeData(initializer);
  }
}

abstract class Import implements Serializable {
  String get module;
  String get name;
}

class ImportedFunction extends BaseFunction implements Import {
  String module;
  String name;

  ImportedFunction(this.module, this.name, int index, FunctionType type)
      : super(index, type);

  @override
  void serialize(Serializer s) {
    s.writeName(module);
    s.writeName(name);
    s.writeByte(0x00);
    s.writeUnsigned(type.index);
  }

  @override
  String toString() => "$module.$name";
}

class ImportedGlobal extends Global implements Import {
  final String module;
  final String name;

  ImportedGlobal(this.module, this.name, int index, GlobalType type)
      : super(index, type);

  @override
  void serialize(Serializer s) {
    s.writeName(module);
    s.writeName(name);
    s.writeByte(0x03);
    s.write(type);
  }
}

abstract class Export implements Serializable {
  final String name;

  Export(this.name);
}

class FunctionExport extends Export {
  final BaseFunction function;

  FunctionExport(String name, this.function) : super(name);

  @override
  void serialize(Serializer s) {
    s.writeName(name);
    s.writeByte(0x00);
    s.writeUnsigned(function.index);
  }
}

class GlobalExport extends Export {
  final Global global;

  GlobalExport(String name, this.global) : super(name);

  @override
  void serialize(Serializer s) {
    s.writeName(name);
    s.writeByte(0x03);
    s.writeUnsigned(global.index);
  }
}

abstract class Section with SerializerMixin implements Serializable {
  final Module module;

  Section(this.module);

  void serialize(Serializer s) {
    if (isNotEmpty) {
      serializeContents();
      s.writeByte(id);
      s.writeUnsigned(data.length);
      s.writeData(this, module.watchPoints);
    }
  }

  int get id;

  bool get isNotEmpty;

  void serializeContents();
}

class TypeSection extends Section {
  TypeSection(Module module) : super(module);

  @override
  int get id => 1;

  @override
  bool get isNotEmpty => module.defTypes.isNotEmpty;

  @override
  void serializeContents() {
    writeUnsigned(module.defTypes.length);
    for (DefType defType in module.defTypes) {
      defType.serializeDefinition(this);
    }
  }
}

class ImportSection extends Section {
  ImportSection(Module module) : super(module);

  @override
  int get id => 2;

  @override
  bool get isNotEmpty => module.imports.isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.imports.toList());
  }
}

class FunctionSection extends Section {
  FunctionSection(Module module) : super(module);

  @override
  int get id => 3;

  @override
  bool get isNotEmpty => module.definedFunctions.isNotEmpty;

  @override
  void serializeContents() {
    writeUnsigned(module.definedFunctions.length);
    for (var function in module.definedFunctions) {
      writeUnsigned(function.type.index);
    }
  }
}

class TableSection extends Section {
  TableSection(Module module) : super(module);

  @override
  int get id => 4;

  @override
  bool get isNotEmpty => module.tables.isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.tables);
  }
}

class MemorySection extends Section {
  MemorySection(Module module) : super(module);

  @override
  int get id => 5;

  @override
  bool get isNotEmpty => module.memories.isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.memories);
  }
}

class GlobalSection extends Section {
  GlobalSection(Module module) : super(module);

  @override
  int get id => 6;

  @override
  bool get isNotEmpty => module.globals.whereType<DefinedGlobal>().isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.globals.whereType<DefinedGlobal>().toList());
  }
}

class ExportSection extends Section {
  ExportSection(Module module) : super(module);

  @override
  int get id => 7;

  @override
  bool get isNotEmpty => module.exports.isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.exports);
  }
}

class StartSection extends Section {
  StartSection(Module module) : super(module);

  @override
  int get id => 8;

  @override
  bool get isNotEmpty => module.startFunction != null;

  @override
  void serializeContents() {
    writeUnsigned(module.startFunction!.index);
  }
}

class _Element implements Serializable {
  final Table table;
  final int startIndex;
  final List<BaseFunction> entries = [];

  _Element(this.table, this.startIndex);

  @override
  void serialize(Serializer s) {
    s.writeUnsigned(table.index);
    s.writeByte(0x41); // i32.const
    s.writeSigned(startIndex);
    s.writeByte(0x0B); // end
    s.writeUnsigned(entries.length);
    for (var entry in entries) {
      s.writeUnsigned(entry.index);
    }
  }
}

class ElementSection extends Section {
  ElementSection(Module module) : super(module);

  @override
  int get id => 9;

  @override
  bool get isNotEmpty =>
      module.tables.any((table) => table.elements.any((e) => e != null));

  @override
  void serializeContents() {
    // Group nonempty element entries into contiguous stretches and serialize
    // each stretch as an element.
    List<_Element> elements = [];
    for (Table table in module.tables) {
      _Element? current = null;
      for (int i = 0; i < table.elements.length; i++) {
        BaseFunction? function = table.elements[i];
        if (function != null) {
          if (current == null) {
            current = _Element(table, i);
            elements.add(current);
          }
          current.entries.add(function);
        } else {
          current = null;
        }
      }
    }
    writeList(elements);
  }
}

class DataCountSection extends Section {
  DataCountSection(Module module) : super(module);

  @override
  int get id => 12;

  @override
  bool get isNotEmpty => module.dataSegments.isNotEmpty;

  @override
  void serializeContents() {
    writeUnsigned(module.dataSegments.length);
  }
}

class CodeSection extends Section {
  CodeSection(Module module) : super(module);

  @override
  int get id => 10;

  @override
  bool get isNotEmpty => module.definedFunctions.isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.definedFunctions.toList());
  }
}

class DataSection extends Section {
  DataSection(Module module) : super(module);

  @override
  int get id => 11;

  @override
  bool get isNotEmpty => module.dataSegments.isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.dataSegments);
  }
}
