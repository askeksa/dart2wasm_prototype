// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:front_end/src/api_unstable/vm.dart'
    show
        CompilerContext,
        CompilerOptions,
        CompilerResult,
        DiagnosticMessage,
        DiagnosticMessageHandler,
        ExperimentalFlag,
        FileSystem,
        FileSystemEntity,
        NnbdMode,
        ProcessedOptions,
        Severity,
        StandardFileSystem,
        getMessageUri,
        kernelForProgram,
        parseExperimentalArguments,
        parseExperimentalFlags,
        printDiagnosticMessage,
        resolveInputUri;

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/library_index.dart';
import 'package:kernel/reference_from_index.dart';
import 'package:kernel/target/changed_structure_notifier.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/transformations/mixin_full_resolution.dart'
    as transformMixins show transformLibraries;
import 'package:kernel/type_environment.dart';

import 'package:vm/kernel_front_end.dart';
import 'package:vm/transformations/type_flow/analysis.dart';
import 'package:vm/transformations/type_flow/calls.dart' show DirectSelector;
import 'package:vm/transformations/lowering.dart' as lowering
    show transformLibraries, transformProcedure;
import 'package:vm/transformations/type_flow/signature_shaking.dart';
import 'package:vm/transformations/type_flow/table_selector_assigner.dart';
import 'package:vm/transformations/type_flow/transformer.dart'
    show CleanupAnnotations, AnnotateKernel, TFADevirtualization, TreeShaker;
import 'package:vm/transformations/type_flow/unboxing_info.dart';

import 'package:dart2wasm/constants_backend.dart';
import 'package:dart2wasm/transformers.dart' as wasmTrans;
import 'package:dart2wasm/translator.dart';

class WasmTarget extends Target {
  @override
  String get name => 'wasm';

  TargetFlags get flags => TargetFlags(enableNullSafety: true);

  @override
  List<String> get extraIndexedLibraries => const <String>[
        "dart:collection",
      ];

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
  ConstantsBackend constantsBackend(CoreTypes coreTypes) =>
      WasmConstantsBackend(coreTypes);

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

  int get enabledConstructorTearOffLowerings => ConstructorTearOffLowering.all;

  @override
  bool get supportsExplicitGetterCalls => true;

  @override
  bool get supportsLateLoweringSentinel => false;

  @override
  bool get useStaticFieldLowering => true;

  @override
  bool enableNative(Uri uri) => true;

  @override
  bool isSupportedPragma(String pragmaName) => pragmaName.startsWith("wasm:");
}

final Map<String, void Function(TranslatorOptions, bool)> boolOptionMap = {
  "export-all": (o, value) => o.exportAll = value,
  "inlining": (o, value) => o.inlining = value,
  "local-nullability": (o, value) => o.localNullability = value,
  "nominal-types": (o, value) => o.nominalTypes = value,
  "parameter-nullability": (o, value) => o.parameterNullability = value,
  "polymorphic-specialization": (o, value) =>
      o.polymorphicSpecialization = value,
  "print-kernel": (o, value) => o.printKernel = value,
  "print-wasm": (o, value) => o.printWasm = value,
  "runtime-types": (o, value) => o.runtimeTypes = value,
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

  CompilerOptions compilerOptions = CompilerOptions()
    ..target = target
    ..compileSdk = true
    ..sdkRoot = Uri.file(Directory("sdk").absolute.path)
    ..environmentDefines = {}
    ..verbose = false;

  CompilerResult? compilerResult =
      await kernelForProgram(mainUri, compilerOptions);
  if (compilerResult == null) return 1;
  Component component = compilerResult.component!;
  CoreTypes coreTypes = compilerResult.coreTypes!;

  final hierarchy = compilerResult.classHierarchy as ClosedWorldClassHierarchy;
  final libraryIndex = new LibraryIndex.all(component);
  final typeFlowAnalysis = TypeFlowAnalysis(
      target,
      component,
      coreTypes,
      hierarchy,
      GenericInterfacesInfoImpl(coreTypes, hierarchy),
      TypeEnvironment(coreTypes, hierarchy),
      libraryIndex,
      null,
      null);
  typeFlowAnalysis.addRawCall(DirectSelector(component.mainMethod!));

  CleanupAnnotations(coreTypes, libraryIndex, null).visitComponent(component);

  typeFlowAnalysis.process();

  final treeShaker =
      TreeShaker(component, typeFlowAnalysis, treeShakeWriteOnlyFields: false);
  treeShaker.transformComponent(component);

  final devirtualization = new TFADevirtualization(
      component, typeFlowAnalysis, hierarchy, treeShaker.fieldMorpher);
  devirtualization.visitComponent(component);

  final tableSelectorAssigner = new TableSelectorAssigner(component);

  final signatureShaker =
      new SignatureShaker(typeFlowAnalysis, tableSelectorAssigner);
  signatureShaker.transformComponent(component);

  // Not used but needed by AnnotateKernel
  final unboxingInfo = new UnboxingInfoManager(typeFlowAnalysis)
    ..analyzeComponent(component, typeFlowAnalysis, tableSelectorAssigner);

  new AnnotateKernel(component, typeFlowAnalysis, treeShaker.fieldMorpher,
          tableSelectorAssigner, unboxingInfo)
      .visitComponent(component);

  var translator = Translator(component, coreTypes,
      TypeEnvironment(coreTypes, hierarchy), tableSelectorAssigner, options);
  File(output).writeAsBytesSync(translator.translate().encode());

  return 0;
}
