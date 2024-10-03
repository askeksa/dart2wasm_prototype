// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Generated by
//
//   pkg/front_end/benchmarks/patterns/generate_datatypes.dart

import '../test_datatypes.dart';

abstract class Base2 {
  void dynamicDispatch(Counter counter);

  R accept<R, A>(Visitor2<R, A> visitor, A arg);
}

class Sub0 extends Base2 {
  @override
  void dynamicDispatch(Counter counter) {
    counter.inc();
  }

  void ifThenElseDispatch0(Counter counter) {
    counter.inc();
  }

  void visitorDispatch0(Counter counter) {
    counter.inc();
  }

  @override
  R accept<R, A>(Visitor2<R, A> visitor, A arg) {
    return visitor.visitSub0(this, arg);
  }
}

class Sub1 extends Base2 {
  @override
  void dynamicDispatch(Counter counter) {
    counter.inc();
  }

  void ifThenElseDispatch1(Counter counter) {
    counter.inc();
  }

  void visitorDispatch1(Counter counter) {
    counter.inc();
  }

  @override
  R accept<R, A>(Visitor2<R, A> visitor, A arg) {
    return visitor.visitSub1(this, arg);
  }
}

List<Base2> createData2() {
  return [
    Sub0(),
    Sub1(),
  ];
}

void incByDynamicDispatch2(Base2 base, Counter counter) {
  base.dynamicDispatch(counter);
}

void incByIfThenElseDispatch2(Base2 base, Counter counter) {
  if (base is Sub0) {
    base.ifThenElseDispatch0(counter);
  } else if (base is Sub1) {
    base.ifThenElseDispatch1(counter);
  }
}

const Visitor2<void, Counter> visitor = CounterVisitor2();

void incByVisitorDispatch2(Base2 base, Counter counter) {
  base.accept(visitor, counter);
}

abstract class Visitor2<R, A> {
  R visitSub0(Sub0 sub, A arg);
  R visitSub1(Sub1 sub, A arg);
}

class CounterVisitor2 implements Visitor2<void, Counter> {
  const CounterVisitor2();

  @override
  void visitSub0(Sub0 sub, Counter counter) {
    sub.visitorDispatch0(counter);
  }

  @override
  void visitSub1(Sub1 sub, Counter counter) {
    sub.visitorDispatch1(counter);
  }
}
