// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:front_end/src/api_unstable/vm.dart'
    show
        CompilerOptions,
        CompilerResult,
        DiagnosticMessage,
        kernelForProgram,
        printDiagnosticMessage,
        resolveInputUri,
        Severity;

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/clone.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/reference_from_index.dart';
import 'package:kernel/target/changed_structure_notifier.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/transformations/mixin_full_resolution.dart'
    as transformMixins show transformLibraries;
import 'package:kernel/type_environment.dart';

import 'package:vm/transformations/type_flow/transformer.dart' as globalTypeFlow
    show transformComponent;

import 'package:dart2wasm/constants_backend.dart';
import 'package:dart2wasm/transformers.dart' as wasmTrans;
import 'package:dart2wasm/translator.dart';

class WasmTarget extends Target {
  Class? _growableList;
  Class? _immutableList;
  Class? _immutableMap;
  Class? _unmodifiableSet;
  Class? _compactLinkedCustomHashMap;
  Class? _compactLinkedHashSet;
  Class? _oneByteString;
  Class? _twoByteString;

  @override
  late final ConstantsBackend constantsBackend;

  @override
  String get name => 'wasm';

  @override
  TargetFlags get flags => TargetFlags(enableNullSafety: true);

  @override
  List<String> get extraIndexedLibraries => const <String>[
        "dart:collection",
        "dart:typed_data",
      ];

  void _patchHostEndian(CoreTypes coreTypes) {
    // Fix Endian.host to be a const field equal to Endian.little instead of
    // a final field. Wasm is a little-endian platform.
    // Can't use normal patching process for this because CFE does not
    // support patching fields.
    // See http://dartbug.com/32836 for the background.
    final Field host =
        coreTypes.index.getField('dart:typed_data', 'Endian', 'host');
    final Field little =
        coreTypes.index.getField('dart:typed_data', 'Endian', 'little');
    host.isConst = true;
    host.initializer = new CloneVisitorNotMembers().clone(little.initializer!)
      ..parent = host;
  }

  @override
  void performPreConstantEvaluationTransformations(
      Component component,
      CoreTypes coreTypes,
      List<Library> libraries,
      DiagnosticReporter diagnosticReporter,
      {void Function(String msg)? logger,
      ChangedStructureNotifier? changedStructureNotifier}) {
    constantsBackend = WasmConstantsBackend(coreTypes);
    _patchHostEndian(coreTypes);
  }

  @override
  void performModularTransformationsOnLibraries(
      Component component,
      CoreTypes coreTypes,
      ClassHierarchy hierarchy,
      List<Library> libraries,
      Map<String, String>? environmentDefines,
      DiagnosticReporter diagnosticReporter,
      ReferenceFromIndex? referenceFromIndex,
      {void logger(String msg)?,
      ChangedStructureNotifier? changedStructureNotifier}) {
    transformMixins.transformLibraries(
        this, coreTypes, hierarchy, libraries, referenceFromIndex);
    logger?.call("Transformed mixin applications");

    wasmTrans.transformLibraries(libraries, coreTypes, hierarchy);
  }

  @override
  void performTransformationsOnProcedure(
      CoreTypes coreTypes,
      ClassHierarchy hierarchy,
      Procedure procedure,
      Map<String, String>? environmentDefines,
      {void logger(String msg)?}) {
    wasmTrans.transformProcedure(procedure, coreTypes, hierarchy);
  }

  @override
  Expression instantiateInvocation(CoreTypes coreTypes, Expression receiver,
      String name, Arguments arguments, int offset, bool isSuper) {
    throw "Unsupported: instantiateInvocation";
  }

  Expression instantiateNoSuchMethodError(CoreTypes coreTypes,
      Expression receiver, String name, Arguments arguments, int offset,
      {bool isMethod: false,
      bool isGetter: false,
      bool isSetter: false,
      bool isField: false,
      bool isLocalVariable: false,
      bool isDynamic: false,
      bool isSuper: false,
      bool isStatic: false,
      bool isConstructor: false,
      bool isTopLevel: false}) {
    throw "Unsupported: instantiateNoSuchMethodError";
  }

  @override
  bool get supportsSetLiterals => false;

  @override
  int get enabledLateLowerings => LateLowering.all;

  @override
  int get enabledConstructorTearOffLowerings => ConstructorTearOffLowering.all;

  @override
  bool get supportsExplicitGetterCalls => true;

  @override
  bool get supportsLateLoweringSentinel => false;

  @override
  bool get useStaticFieldLowering => false;

  @override
  bool enableNative(Uri uri) => true;

  @override
  Class concreteListLiteralClass(CoreTypes coreTypes) {
    return _growableList ??=
        coreTypes.index.getClass('dart:core', '_GrowableList');
  }

  @override
  Class concreteConstListLiteralClass(CoreTypes coreTypes) {
    return _immutableList ??=
        coreTypes.index.getClass('dart:core', '_ImmutableList');
  }

  @override
  Class concreteMapLiteralClass(CoreTypes coreTypes) {
    return _compactLinkedCustomHashMap ??= coreTypes.index
        .getClass('dart:collection', '_CompactLinkedCustomHashMap');
  }

  @override
  Class concreteConstMapLiteralClass(CoreTypes coreTypes) {
    return _immutableMap ??=
        coreTypes.index.getClass('dart:collection', '_ImmutableMap');
  }

  @override
  Class concreteSetLiteralClass(CoreTypes coreTypes) {
    return _compactLinkedHashSet ??=
        coreTypes.index.getClass('dart:collection', '_CompactLinkedHashSet');
  }

  @override
  Class concreteConstSetLiteralClass(CoreTypes coreTypes) {
    return _unmodifiableSet ??=
        coreTypes.index.getClass('dart:collection', '_UnmodifiableSet');
  }

  @override
  Class concreteStringLiteralClass(CoreTypes coreTypes, String value) {
    const int maxLatin1 = 0xff;
    for (int i = 0; i < value.length; ++i) {
      if (value.codeUnitAt(i) > maxLatin1) {
        return _twoByteString ??=
            coreTypes.index.getClass('dart:core', '_TwoByteString');
      }
    }
    return _oneByteString ??=
        coreTypes.index.getClass('dart:core', '_OneByteString');
  }

  @override
  bool isSupportedPragma(String pragmaName) => pragmaName.startsWith("wasm:");
}

final Map<String, void Function(TranslatorOptions, bool)> boolOptionMap = {
  "export-all": (o, value) => o.exportAll = value,
  "inlining": (o, value) => o.inlining = value,
  "lazy-constants": (o, value) => o.lazyConstants = value,
  "local-nullability": (o, value) => o.localNullability = value,
  "nominal-types": (o, value) => o.nominalTypes = value,
  "parameter-nullability": (o, value) => o.parameterNullability = value,
  "polymorphic-specialization": (o, value) =>
      o.polymorphicSpecialization = value,
  "print-kernel": (o, value) => o.printKernel = value,
  "print-wasm": (o, value) => o.printWasm = value,
  "runtime-types": (o, value) => o.runtimeTypes = value,
  "string-data-segments": (o, value) => o.stringDataSegments = value,
  "stub-bodies": (o, value) => o.stubBodies = value,
};
final Map<String, void Function(TranslatorOptions, int)> intOptionMap = {
  "watch": (o, value) => (o.watchPoints ??= []).add(value),
};

Never usage(String message) {
  print("Usage: dart2wasm [<options>] <infile.dart> <outfile.wasm>");
  print("");
  print("Options:");
  for (String option in boolOptionMap.keys) {
    print("  --[no-]$option");
  }
  for (String option in intOptionMap.keys) {
    print("  --$option <value>");
  }
  print("");

  throw message;
}

Future<int> main(List<String> args) async {
  TranslatorOptions options = TranslatorOptions();
  List<String> nonOptions = [];
  void Function(TranslatorOptions, int)? intOptionFun = null;
  for (String arg in args) {
    if (intOptionFun != null) {
      intOptionFun(options, int.parse(arg));
      intOptionFun = null;
    } else if (arg.startsWith("--dart-sdk")) {
    } else if (arg.startsWith("--no-")) {
      var optionFun = boolOptionMap[arg.substring(5)];
      if (optionFun == null) usage("Unknown option $arg");
      optionFun(options, false);
    } else if (arg.startsWith("--")) {
      var optionFun = boolOptionMap[arg.substring(2)];
      if (optionFun != null) {
        optionFun(options, true);
      } else {
        intOptionFun = intOptionMap[arg.substring(2)];
        if (intOptionFun == null) usage("Unknown option $arg");
      }
    } else {
      nonOptions.add(arg);
    }
  }
  if (intOptionFun != null) {
    usage("Missing argument to ${args.last}");
  }

  if (nonOptions.length != 2) usage("Requires two file arguments");
  String input = nonOptions[0];
  String output = nonOptions[1];
  Uri mainUri = resolveInputUri(input);

  Target target = WasmTarget();
  var succeeded = true;
  void diagnosticMessageHandler(DiagnosticMessage message) {
    if (message.severity == Severity.error) {
      succeeded = false;
    }
    printDiagnosticMessage(message, print);
  }

  CompilerOptions compilerOptions = CompilerOptions()
    ..target = target
    ..compileSdk = true
    ..sdkRoot = Uri.file(Directory("sdk").absolute.path)
    ..environmentDefines = {}
    ..verbose = false
    ..onDiagnostic = diagnosticMessageHandler;

  CompilerResult? compilerResult =
      await kernelForProgram(mainUri, compilerOptions);
  if (compilerResult == null || !succeeded) {
    exitCode = 1;
    return exitCode;
  }
  Component component = compilerResult.component!;
  CoreTypes coreTypes = compilerResult.coreTypes!;

  globalTypeFlow.transformComponent(target, coreTypes, component,
      treeShakeSignatures: true,
      treeShakeWriteOnlyFields: true,
      useRapidTypeAnalysis: false);

  var translator = Translator(component, coreTypes,
      TypeEnvironment(coreTypes, compilerResult.classHierarchy!), options);
  File(output).writeAsBytesSync(translator.translate().encode());

  return 0;
}
