// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "internal_patch.dart";

@patch
void printToConsole(String line) {
  printToConsoleJS(ensureTwoByteString(line));
}

@pragma("wasm:import", "dart2wasm.printToConsole")
external void printToConsoleJS(String line);
