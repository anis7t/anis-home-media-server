/// Base exception for application-level errors.
class AppException implements Exception {
  final String message;
  final int? statusCode;
  final dynamic details;

  const AppException(
    this.message, {
    this.statusCode,
    this.details,
  });

  @override
  String toString() {
    if (statusCode != null) {
      return 'AppException ($statusCode): $message';
    }
    return 'AppException: $message';
  }
}

class NetworkException extends AppException {
  const NetworkException(super.message, {super.statusCode, super.details});
}

class ServerException extends AppException {
  const ServerException(super.message, {super.statusCode, super.details});
}

class StorageException extends AppException {
  const StorageException(super.message, {super.details});
}

class ValidationException extends AppException {
  const ValidationException(super.message, {super.details});
}

class UnauthorizedException extends AppException {
  const UnauthorizedException(super.message, {super.statusCode = 401, super.details});
}
