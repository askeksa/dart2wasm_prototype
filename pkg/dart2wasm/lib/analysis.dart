// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';

import 'translator.dart';

class ProgramAnalyzer extends RecursiveVisitor {
  Translator translator;

  Set<String> dynamicGets = {};

  ProgramAnalyzer(this.translator);

  void visitDynamicGet(DynamicGet node) {
    super.visitDynamicGet(node);
    dynamicGets.add(node.name.text);
  }
}
