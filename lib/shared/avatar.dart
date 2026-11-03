import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'common.dart';

/// Round profile picture; falls back to the person's initials.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    this.url,
    this.bytes,
    this.radius = 20,
  });
  final String name;
  final String? url;
  final Uint8List? bytes; // a just-picked photo, not uploaded yet
  final double radius;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = bytes != null
        ? MemoryImage(bytes!)
        : ((url ?? '').isNotEmpty ? NetworkImage(url!) : null);
    return CircleAvatar(
      radius: radius,
      backgroundImage: image,
      // If the link is broken, show the plain circle instead of an error.
      onBackgroundImageError: image is NetworkImage ? (_, _) {} : null,
      child: image == null
          ? (_initials.isEmpty
              ? Icon(Icons.person, size: radius)
              : Text(_initials, style: TextStyle(fontSize: radius * 0.8)))
          : null,
    );
  }
}

/// Large avatar with an "Add / Change photo" button. Reports the picked photo
/// through [onPicked]; the parent decides when to upload it.
class AvatarPicker extends StatefulWidget {
  const AvatarPicker(
      {super.key, required this.name, this.url, required this.onPicked});
  final String name;
  final String? url;
  final ValueChanged<Uint8List> onPicked;

  @override
  State<AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends State<AvatarPicker> {
  Uint8List? _bytes;

  Future<void> _choose() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.of(context).pop(ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.of(context).pop(ImageSource.camera),
          ),
        ]),
      ),
    );
    if (source == null) return;
    try {
      // Shrunk on the phone so uploads stay small.
      final file = await ImagePicker().pickImage(
          source: source, maxWidth: 600, maxHeight: 600, imageQuality: 80);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() => _bytes = bytes);
      widget.onPicked(bytes);
    } catch (_) {
      if (mounted) snack(context, 'Could not open the photo picker.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final has = _bytes != null || (widget.url ?? '').isNotEmpty;
    return Column(children: [
      GestureDetector(
        onTap: _choose,
        child: Avatar(
            name: widget.name, url: widget.url, bytes: _bytes, radius: 48),
      ),
      TextButton.icon(
        onPressed: _choose,
        icon: const Icon(Icons.photo_camera_outlined),
        label: Text(has ? 'Change photo' : 'Add photo'),
      ),
    ]);
  }
}

/// Uploads a profile picture and saves its link on the person's profile.
/// Throws if the upload or the save fails.
Future<void> uploadAvatar(String userId, Uint8List bytes) async {
  final path = '$userId.jpg';
  final store = db.storage.from('avatars');
  await store.uploadBinary(path, bytes,
      fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'));
  // The ?v= part makes phones fetch the new picture instead of an old cached one.
  final url = '${store.getPublicUrl(path)}?v=${DateTime.now().millisecondsSinceEpoch}';
  await db.from('profiles').update({'avatar_url': url}).eq('id', userId);
}
