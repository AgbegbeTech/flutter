// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as path;
import 'package:process/process.dart';
import 'package:vm_snapshot_analysis/program_info.dart';
import 'package:vm_snapshot_analysis/v8_profile.dart';

const ProcessManager processManager = LocalProcessManager();
const FileSystem fs = LocalFileSystem();

Future<void> main(List<String> args) async {
  final Options options = Options.fromArgs(args);
  final String json = options.snapshot.readAsStringSync();
  final Snapshot snapshot = Snapshot.fromJson(jsonDecode(json) as Map<String, dynamic>);
  final ProgramInfo programInfo = toProgramInfo(snapshot);

  final List<String> foundForbiddenTypes = <String>[];
  bool fail = false;
  for (final String forbiddenType in options.forbiddenTypes) {
    final int slash = forbiddenType.indexOf('/');
    final int doubleColons = forbiddenType.indexOf('::');
    if (slash == -1 || doubleColons < 2) {
      print('Invalid forbidden type "$forbiddenType". The format must be <package_uri>::<type_name>, e.g. package:flutter/src/widgets/framework.dart::Widget');
      fail = true;
      continue;
    }

    if (!await validateType(forbiddenType, options.packageConfig)) {
      foundForbiddenTypes.add('Forbidden type "$forbiddenType" does not seem to exist.');
      continue;
    }

    final List<String> lookupPath = <String>[
      forbiddenType.substring(0, slash),
      forbiddenType.substring(0, doubleColons),
      forbiddenType.substring(doubleColons + 2),
    ];
    if (programInfo.lookup(lookupPath) != null) {
      foundForbiddenTypes.add(forbiddenType);
    }
  }
  if (fail) {
    print('Invalid forbidden type formats. Exiting.');
    exit(-1);
  }
  if (foundForbiddenTypes.isNotEmpty) {
    print('The output contained the following forbidden types:');
    print(foundForbiddenTypes.join('\n'));
    exit(-1);
  }

  print('No forbidden types found.');
}

Future<bool> validateType(String forbiddenType, File packageConfigFile) async {
  if (!forbiddenType.startsWith('package:')) {
    print('Warning: Unable to validate $forbiddenType. Continuing.');
    return true;
  }

  final Uri packageUri = Uri.parse(forbiddenType.substring(0, forbiddenType.indexOf('::')));
  final String typeName = forbiddenType.substring(forbiddenType.indexOf('::') + 2);

  final PackageConfig packageConfig = PackageConfig.parseString(
    packageConfigFile.readAsStringSync(),
    packageConfigFile.uri,
  );
  final Uri? packageFileUri = packageConfig.resolve(packageUri);
  final File packageFile = fs.file(packageFileUri);
  if (!packageFile.existsSync()) {
    print('File $packageFile does not exist - forbidden type has moved or been removed.');
    return false;
  }

  // This logic is imperfect. It will not detect mixed in types the way that
  // the snapshot has them, e.g. TypeName&MixedIn&Whatever. It also assumes
  // there is at least one space before and after the type name, which is not
  // strictly required by the language.
  final List<String> contents = packageFile.readAsStringSync().split('\n');
  for (final String line in contents) {
    // Ignore comments.
    // This will fail for multi- and intra-line comments (i.e. /* */).
    if (line.trim().startsWith('//')) {
      continue;
    }
    if (line.contains(' $typeName ')) {
      return true;
    }
  }
  return false;
}

class Options {
  const Options({
    required this.snapshot,
    required this.packageConfig,
    required this.forbiddenTypes,
  });

  factory Options.fromArgs(List<String> args) {
    final ArgParser argParser = ArgParser();
    argParser.addOption(
      'snapshot',
      help: 'The path V8 snapshot file.',
      valueHelp: '/tmp/snapshot.arm64-v8a.json',
    );
    argParser.addOption(
      'package-config',
      help: 'Dart package_config.json file generated by `pub get`.',
      valueHelp: path.join(r'$FLUTTER_ROOT', 'examples', 'hello_world', '.dart_tool', 'package_config.json'),
      defaultsTo: path.join(fs.currentDirectory.path, 'examples', 'hello_world', '.dart_tool', 'package_config.json'),
    );
    argParser.addMultiOption(
      'forbidden-type',
      help: 'Type name(s) to forbid from release compilation, e.g. "package:flutter/src/widgets/framework.dart::Widget".',
      valueHelp: '<package_uri>::<type_name>',
    );

    argParser.addFlag('help', help: 'Prints usage.', negatable: false);
    final ArgResults argResults = argParser.parse(args);

    if (argResults['help'] == true) {
      print(argParser.usage);
      exit(0);
    }

    return Options(
      snapshot: _getFileArg(argResults, 'snapshot'),
      packageConfig: _getFileArg(argResults, 'package-config'),
      forbiddenTypes: Set<String>.from(argResults['forbidden-type'] as List<String>),
    );
  }

  final File snapshot;
  final File packageConfig;
  final Set<String> forbiddenTypes;

  static File _getFileArg(ArgResults argResults, String argName) {
    final File result = fs.file(argResults[argName] as String);
    if (!result.existsSync()) {
      print('The $argName file at $result could not be found.');
      exit(-1);
    }
    return result;
  }
}