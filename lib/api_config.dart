class ApiConfig {
  static const renderBackendUrl = 'https://travelwithmeai-server.onrender.com';
  static const customDomainBackendUrl = 'https://api.travelwithmeai.com';

  static const backendBaseUrl = String.fromEnvironment(
    'TRAVELWITHMEAI_API_BASE_URL',
    defaultValue: renderBackendUrl,
  );

  static Uri endpoint(String path) {
    final base = backendBaseUrl.endsWith('/')
        ? backendBaseUrl.substring(0, backendBaseUrl.length - 1)
        : backendBaseUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$cleanPath');
  }
}
