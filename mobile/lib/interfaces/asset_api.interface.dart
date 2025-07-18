import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/entities/asset.entity.dart';

abstract interface class IAssetApiRepository {
  // Future<Asset> get(String id);

  // Future<List<Asset>> getAll();

  // Future<Asset> create(Asset asset);

  Future<Asset> update(
    String id, {
    String? description,
  });

  // Future<void> delete(String id);

  Future<List<Asset>> search({List<String> personIds = const []});

  Future<void> updateVisibility(
    List<String> list,
    AssetVisibilityEnum visibility,
  );

  Future<String?> getAssetMIMEType(String id);
}
