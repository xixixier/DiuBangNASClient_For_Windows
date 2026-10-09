import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasclient/core/path/nas_path.dart';
import 'package:nasclient/features/files/domain/entities/file_category.dart';
import 'package:nasclient/features/files/domain/entities/file_entry_entity.dart';
import 'package:nasclient/features/files/domain/entities/file_type.dart';
import 'package:nasclient/features/files/presentation/cubit/file_browser_cubit.dart';
import 'package:nasclient/features/files/presentation/cubit/file_browser_state.dart';
import 'package:nasclient/features/files/presentation/pages/file_browser_page.dart';
import 'package:nasclient/features/transfer/domain/entities/transfer_direction.dart';
import 'package:nasclient/features/transfer/domain/entities/transfer_status.dart';
import 'package:nasclient/features/transfer/domain/entities/transfer_task_entity.dart';
import 'package:nasclient/features/transfer/presentation/cubit/transfer_cubit.dart';
import 'package:nasclient/features/transfer/presentation/cubit/transfer_state.dart';
import 'package:nasclient/features/transfer/presentation/widgets/desktop_transfer_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeFileCubit extends Cubit<FileBrowserState> implements FileBrowserCubit {
  FakeFileCubit(super.initial);
  @override
  FileCategory get currentCategory => FileCategory.photo;
  @override
  String get currentSortBy => 'modified';
  @override
  String get currentSortOrder => 'desc';
  @override
  String get currentRootId => 'fs';
  @override
  Uint8List? getThumbnail(String filePath) => null;
  @override
  Stream<void> watchThumbnail(String filePath) => const Stream<void>.empty();
  @override
  void setSelection(Set<String> paths) {
    final s = state as FileBrowserLoaded;
    emit(s.copyWith(selectionMode: paths.isNotEmpty, selectedPaths: paths));
  }
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isMethod) {
      final name = invocation.memberName.toString();
      if (name.contains('loadMore') || name.contains('refresh') || name.contains('switch') || name.contains('change') || name.contains('loadRoot') || name.contains('batchDelete')) {
        return Future<void>.value();
      }
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}

class FakeTransferCubit extends Cubit<TransferState> implements TransferCubit {
  FakeTransferCubit(super.initial);
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('file browser page: grid, list, selection, menus, keyboard', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final files = List.generate(
      40,
      (i) => FileEntryEntity(
        name: 'IMG_$i.jpg',
        path: '/IMG_$i.jpg',
        type: FileType.file,
        size: 1000 * i,
        modifiedAt: DateTime(2026, 1, 1).add(Duration(hours: i)),
      ),
    );
    final cubit = FakeFileCubit(
      FileBrowserLoaded(
        allFiles: files,
        filteredFiles: files,
        mediaFiles: files,
        currentPath: NasPath.root('fs'),
        currentRootId: 'fs',
        currentRootWritable: true,
        currentCategory: FileCategory.photo,
        hasMore: true,
      ),
    );
    final transfer = FakeTransferCubit(
      TransferLoaded(
        tasks: [
          TransferTaskEntity(
            id: 't1',
            rootId: 'fs',
            localPath: 'C:/a.jpg',
            remotePath: '/a.jpg',
            fileName: 'a.jpg',
            totalBytes: 100,
            transferredBytes: 40,
            direction: TransferDirection.upload,
            status: TransferStatus.transferring,
            createdAt: DateTime(2026),
          ),
        ],
        activeCount: 1,
        completedCount: 0,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultiBlocProvider(
            providers: [
              BlocProvider<FileBrowserCubit>.value(value: cubit),
              BlocProvider<TransferCubit>.value(value: transfer),
            ],
            child: Row(
              children: [
                const Expanded(child: FileBrowserPage()),
                ValueListenableBuilder<bool>(
                  valueListenable: DesktopShellState.transferPanelOpen,
                  builder: (context, open, _) => open
                      ? DesktopTransferPanel(onClose: () => DesktopShellState.transferPanelOpen.value = false)
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400)); await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.text('IMG_0.jpg'), findsOneWidget);

    // single click selects
    await tester.tapAt(tester.getCenter(find.text('IMG_1.jpg')));
    await tester.pump(const Duration(milliseconds: 600));
    expect((cubit.state as FileBrowserLoaded).selectedPaths, {'/IMG_1.jpg'});

    // ctrl+click adds
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(tester.getCenter(find.text('IMG_3.jpg')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 600));
    expect((cubit.state as FileBrowserLoaded).selectedPaths, {'/IMG_1.jpg', '/IMG_3.jpg'});

    // ctrl+a
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect((cubit.state as FileBrowserLoaded).selectedPaths.length, 40);
    expect(find.textContaining('已选择 40 项'), findsWidgets);

    // escape clears
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect((cubit.state as FileBrowserLoaded).selectedPaths, isEmpty);

    // arrow right selects first
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect((cubit.state as FileBrowserLoaded).selectedPaths.length, 1);

    // right-click opens context menu
    final g = await tester.startGesture(tester.getCenter(find.text('IMG_2.jpg')), kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await g.up();
    await tester.pump(const Duration(milliseconds: 400)); await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('下载到…'), findsWidgets);
    expect(find.text('属性'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('属性'));
    await tester.pump(const Duration(milliseconds: 400)); await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('修改日期'), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('确定'));
    await tester.pump(const Duration(milliseconds: 400)); await tester.pump(const Duration(milliseconds: 400));

    // marquee from empty area
    final gridRect = tester.getRect(find.byType(CustomScrollView));
    final m = await tester.startGesture(Offset(gridRect.left + 4, gridRect.top + 4), kind: PointerDeviceKind.mouse);
    await m.moveTo(Offset(gridRect.left + 400, gridRect.top + 300));
    await tester.pump();
    await m.up();
    await tester.pump();
    final marqueeSel = (cubit.state as FileBrowserLoaded).selectedPaths.length;
    expect(marqueeSel, greaterThan(1));

    // list view
    await tester.tap(find.byTooltip('详细信息'));
    await tester.pump(const Duration(milliseconds: 400)); await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('修改日期'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // search filter
    await tester.enterText(find.byType(TextField), 'IMG_3');
    await tester.pump(const Duration(milliseconds: 400)); await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('找到'), findsOneWidget);

    // transfer panel
    await tester.tap(find.text('上传 1'));
    await tester.pump(const Duration(milliseconds: 400)); await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('a.jpg'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // background context menu
    final b = await tester.startGesture(Offset(gridRect.left + 300, gridRect.bottom - 20), kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await b.up();
    await tester.pump(const Duration(milliseconds: 400)); await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('上传文件…'), findsOneWidget);

    // narrow window
    tester.view.physicalSize = const Size(1000, 680);
    await tester.pump(const Duration(milliseconds: 400)); await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });
}
