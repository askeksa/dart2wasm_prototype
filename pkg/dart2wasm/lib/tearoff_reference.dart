// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';

Expando<Reference> _tearOffReference = Expando();

extension TearOffReference on Procedure {
  Reference get tearOffReference =>
      _tearOffReference[this] ??= Reference()..node = this;
}

extension IsTearOffReference on Reference {
  bool get isTearOffReference {
    Member member = asMember;
    return member is Procedure && member.tearOffReference == this;
  }
}

extension ReferenceAs on Member {
  Reference referenceAs({required bool getter, required bool setter}) {
    Member member = this;
    return member is Field
        ? setter
            ? member.setterReference!
            : member.getterReference
        : getter && member is Procedure && member.kind == ProcedureKind.Method
            ? member.tearOffReference
            : member.reference;
  }
}
