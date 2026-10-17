import '../core/api_client.dart';

/// The signed-in shop owner.
///
/// Deliberately has no password field: the server never sends `password_hash`,
/// so there is nothing here that could be logged or accidentally rendered.
class User {
  const User({
    required this.id,
    required this.fullName,
    required this.username,
    this.email,
    this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id']?.toString() ?? '',
    fullName: json['fullName']?.toString() ?? '',
    username: json['username']?.toString() ?? '',
    email: asString(json['email']),
    createdAt: asDateTime(json['createdAt']),
  );

  final String id;
  final String fullName;
  final String username;
  final String? email;
  final DateTime? createdAt;

  /// First name, for greetings. Falls back to the username.
  String get shortName {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return username;
    return trimmed.split(' ').first;
  }

  /// One or two letters for the avatar circle.
  String get initials {
    final parts = fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return username.isEmpty ? '?' : username[0].toUpperCase();
    }
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}
