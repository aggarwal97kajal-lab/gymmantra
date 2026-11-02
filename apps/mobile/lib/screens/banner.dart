import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../i18n.dart';
import '../theme.dart';
import '../ui.dart';

/// Picks a banner picture from the gallery and crops it to 2:1 (shown wide on dashboards).
/// Kept small (≤ 1200 px wide, JPEG) so it uploads in a second.
Future<Uint8List?> pickBanner(BuildContext context) async {
  final title = context.t('Crop banner');
  try {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1800, imageQuality: 90);
    if (file == null) return null;
    final cropped = await ImageCropper().cropImage(
      sourcePath: file.path,
      maxWidth: 1200,
      maxHeight: 600,
      compressQuality: 80,
      compressFormat: ImageCompressFormat.jpg,
      aspectRatio: const CropAspectRatio(ratioX: 2, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: title,
          toolbarColor: C.night,
          toolbarWidgetColor: Colors.white,
          backgroundColor: Colors.black,
          activeControlsWidgetColor: C.orange,
          lockAspectRatio: true,
          hideBottomControls: false,
        ),
        IOSUiSettings(title: title, aspectRatioLockEnabled: true),
      ],
    );
    if (cropped == null) return null;
    final bytes = await cropped.readAsBytes();
    if (bytes.length > 400 * 1024) {
      if (context.mounted) toast(context, 'Banner must be smaller than 400 KB');
      return null;
    }
    return bytes;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return null;
  }
}

/// "Add banner" box with the picked picture and change / remove buttons.
class BannerPickerBox extends StatelessWidget {
  const BannerPickerBox({super.key, required this.has, required this.onPick, required this.onRemove});
  final bool has;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final p = context.c;
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46), side: BorderSide(color: p.primary, width: 1.3), foregroundColor: p.primary),
          onPressed: onPick,
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 19),
          label: Text(context.t(has ? 'Change banner' : 'Add banner picture')),
        ),
      ),
      if (has) ...[
        const SizedBox(width: 8),
        IconButton.outlined(onPressed: onRemove, icon: const Icon(Icons.delete_outline_rounded, color: C.red)),
      ],
    ]);
  }
}
