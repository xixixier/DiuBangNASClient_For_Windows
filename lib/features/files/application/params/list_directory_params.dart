import '../../../../core/path/nas_path.dart';
import '../../domain/entities/file_category.dart';

class ListDirectoryParams {
  const ListDirectoryParams({
    required this.path,
    required this.category,
    this.cursor,
    this.limit = 120,
    this.sortBy,
    this.sortOrder,
    this.folderView = false,
  });

  final NasPath path;
  final FileCategory category;
  final String? cursor;
  final int limit;

  /// 排序字段：'modified'（默认） | 'size'
  final String? sortBy;

  /// 排序方向：'desc'（默认） | 'asc'
  final String? sortOrder;

  /// 文件夹视图：按真实目录逐级浏览（WebDAV），返回当前目录下的文件夹和全部文件，
  /// 不按分类过滤。分类视图则走服务端索引，平铺列出全部文件。
  final bool folderView;
}
