/// 文件输入：源路径、目标路径
/// 文件职责：移动或重命名文件/文件夹
/// 文件对外接口：MoveEntryUseCase
/// 文件包含：MoveEntryUseCase
import '../../../../core/path/nas_path.dart';
import '../../../../core/result/app_result.dart';
import '../../domain/repositories/file_repository.dart';

class MoveEntryUseCase {
  MoveEntryUseCase({required FileRepository repository})
    : _repository = repository;

  final FileRepository _repository;

  Future<AppResult<void>> call(NasPath from, NasPath to) {
    return _repository.moveEntry(from, to);
  }
}
