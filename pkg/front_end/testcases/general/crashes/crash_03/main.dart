import 'main_lib.dart';

class Offset {}

class PlatformViewRenderBox extends RenderBox with _PlatformViewGestureMixin {}

mixin _PlatformViewGestureMixin on RenderBox implements MouseTrackerAnnotation {
  bool hitTestSelf(Offset position) =>
      _hitTestBehavior != PlatformViewHitTestBehavior.transparent;
}

main() {}
