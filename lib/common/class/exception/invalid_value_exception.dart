import "package:flutter/foundation.dart";

/// 値不正例外
///
/// 値が指定された要件を満たさなかった場合にthrowする例外です。
@immutable
class InvalidValueException<T> implements Exception {
  final T invalidValue;
  final String message;

  const InvalidValueException({
    required this.invalidValue,
    required this.message,
  });

  @override
  String toString() => "${runtimeType.toString()}: $message, but was $invalidValue.";
}
