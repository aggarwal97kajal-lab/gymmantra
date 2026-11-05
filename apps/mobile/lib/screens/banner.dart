import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../api.dart';
import '../i18n.dart';
import '../photo.dart';
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
    if (!has) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46), side: BorderSide(color: p.primary, width: 1.3), foregroundColor: p.primary),
        onPressed: onPick,
        icon: const Icon(Icons.add_photo_alternate_outlined, size: 19),
        label: Text(context.t('Add banner picture')),
      );
    }
    // Big buttons under the picture (not a small icon in the corner).
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: p.fg),
          onPressed: onPick,
          icon: const Icon(Icons.image_outlined, size: 19),
          label: Text(context.t('Change photo')),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: C.red, side: BorderSide(color: C.red.withAlpha(110))),
          onPressed: onRemove,
          icon: const Icon(Icons.close_rounded, size: 19),
          label: Text(context.t('Remove')),
        ),
      ),
    ]);
  }
}

/// Picks a gym / branch logo: gallery → square crop → small JPEG (≤ 300 KB).
Future<Uint8List?> pickLogo(BuildContext context) async {
  final title = context.t('Crop logo');
  try {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1200, imageQuality: 92);
    if (file == null) return null;
    final cropped = await ImageCropper().cropImage(
      sourcePath: file.path,
      maxWidth: 512,
      maxHeight: 512,
      compressQuality: 82,
      compressFormat: ImageCompressFormat.jpg,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: title,
          toolbarColor: C.night,
          toolbarWidgetColor: Colors.white,
          backgroundColor: Colors.black,
          activeControlsWidgetColor: C.orange,
          lockAspectRatio: true,
        ),
        IOSUiSettings(title: title, aspectRatioLockEnabled: true),
      ],
    );
    if (cropped == null) return null;
    final bytes = await cropped.readAsBytes();
    if (bytes.length > 300 * 1024) {
      if (context.mounted) toast(context, context.t('Logo must be smaller than 300 KB'));
      return null;
    }
    return bytes;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return null;
  }
}

/// Uploads a logo for the gym (branchId null) or one branch. Returns its new link.
Future<String?> uploadLogo(Uint8List bytes, {String? branchId}) async {
  final r = await Api.instance.put('/gym/logo', {'mime': 'image/jpeg', 'base64': base64Encode(bytes), if (branchId != null) 'branchId': branchId});
  final url = (r as Map)['logoUrl'] as String?;
  if (url != null) PhotoCache.put(url, bytes);
  return url;
}

/// Logo box for forms: the logo (or + when none) with Change / Remove.
class LogoPickerRow extends StatelessWidget {
  const LogoPickerRow({super.key, required this.name, required this.title, required this.hint, this.url, this.local, required this.onPick, this.onRemove});
  final String name;
  final String title;
  final String hint;
  final String? url;
  final Uint8List? local;
  final VoidCallback onPick;
  final VoidCallback? onRemove;
  @override
  Widget build(BuildContext context) {
    final has = local != null || (url ?? '').isNotEmpty;
    final p = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(children: [
        InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onPick,
          child: has
              ? GymLogo(name: name, url: url, local: local, size: 68)
              : Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(19), border: Border.all(color: p.line, width: 1.6)),
                  child: Icon(Icons.add_photo_alternate_outlined, color: p.mut),
                ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            Text(hint, style: TextStyle(color: p.mut, fontSize: 12.5)),
            Wrap(spacing: 4, children: [
              TextButton(style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: const Size(0, 32)), onPressed: onPick, child: Text(context.t(has ? 'Change logo' : 'Add logo'))),
              if (has && onRemove != null)
                TextButton(style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: const Size(0, 32), foregroundColor: C.red), onPressed: onRemove, child: Text(context.t('Remove'))),
            ]),
          ]),
        ),
      ]),
    );
  }
}
