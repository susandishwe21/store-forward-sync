/// Turns ["--kills=200", "--drain"] into {"kills": "200", "drain": "true"}.
Map<String, String> parseOptions(List<String> args) => {
  for (final arg in args)
    if (arg.startsWith('--'))
      if (arg.contains('='))
        arg.substring(2, arg.indexOf('=')): arg.substring(arg.indexOf('=') + 1)
      else
        arg.substring(2): 'true',
};
