/// 文件输入：AppRouter、AppTheme
/// 文件职责：组装根级 MaterialApp.router，提供应用入口组件
/// 文件对外接口：App
/// 文件包含：App
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import '../features/startup/application/use_cases/resolve_start_route_use_case.dart';

class App extends StatelessWidget {
  final ResolveStartRouteUseCase? resolveStartRouteUseCase;
  const App({super.key, this.resolveStartRouteUseCase});

  @override
  Widget build(BuildContext context) {
    final router = buildAppRouter(resolveStartRouteUseCase: resolveStartRouteUseCase);

    return MaterialApp.router(
      title: '铥棒文件',
      theme: buildAppTheme(),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      // 桌面端：允许鼠标/触控板拖动滚动（图库 PageView、滚轮选择器等依赖拖动手势）
      scrollBehavior: const _AppScrollBehavior(),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };
}
