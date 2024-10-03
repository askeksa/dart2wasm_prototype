// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class A<X> {}
class B<X> extends A<X> {}
class C extends B<int> {}

extension type E on C show B<int> hide A<int> {}

class A2 {}
class B2 extends A2 {}
class C2 extends B2 {}

extension type E2 on C2 show B2 hide A2 {}

class A3 {
  void foo() {}
  int? field;
  String? field2;
  int get getter => 42;
  void set setter(int value) {}
  void set setter2(int value) {}
  void set setter3(int value) {}
  A3 operator +(A3 other) => other;
  A3 operator *(A3 other) => this;
}

class B3 extends A3 {
  void bar() {}
}

class C3 extends B3 {
  void baz() {}
}

extension type E3 on C3
  show B3, baz, field, setter, set field2, operator +
  hide foo, get field, getter, setter2, set setter3, operator * {}

main() {}
