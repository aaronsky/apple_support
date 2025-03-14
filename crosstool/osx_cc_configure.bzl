# pylint: disable=g-bad-file-header
# Copyright 2016 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Configuring the C++ toolchain on macOS."""

load(
    "@bazel_tools//tools/cpp:lib_cc_configure.bzl",
    "escape_string",
)
load("@bazel_tools//tools/osx:xcode_configure.bzl", "run_xcode_locator")

def _get_escaped_xcode_cxx_inc_directories(repository_ctx, xcode_toolchains):
    """Compute the list of default C++ include paths on Xcode-enabled darwin.

    Args:
      repository_ctx: The repository context.
      xcode_toolchains: A list containing the xcode toolchains available
    Returns:
      include_paths: A list of builtin include paths.
    """

    # Assume that everything is managed by Xcode / toolchain installations
    include_dirs = [
        "/Applications/",
        "/Library/",
    ]

    user = repository_ctx.os.environ.get("USER")
    if user:
        include_dirs.extend([
            "/Users/{}/Applications/".format(user),
            "/Users/{}/Library/".format(user),
        ])

    # Include extra Xcode paths in case they're installed on other volumes
    for toolchain in xcode_toolchains:
        include_dirs.append(escape_string(toolchain.developer_dir))

    return include_dirs

def _succeeds(repository_ctx, *args):
    env = repository_ctx.os.environ
    result = repository_ctx.execute([
        "env",
        "-i",
        "DEVELOPER_DIR={}".format(env.get("DEVELOPER_DIR", default = "")),
        "xcrun",
        "--sdk",
        "macosx",
    ] + list(args))

    return result.return_code == 0

def _generate_system_modulemap(repository_ctx, script, output):
    env = repository_ctx.os.environ
    result = repository_ctx.execute([
        "env",
        "-i",
        "DEVELOPER_DIR={}".format(env.get("DEVELOPER_DIR", default = "")),
        script,
    ])

    if result.return_code != 0:
        error_msg = (
            "return code {code}, stderr: {err}, stdout: {out}"
        ).format(
            code = result.return_code,
            err = result.stderr,
            out = result.stdout,
        )
        fail(output + " failed to generate. Please file an issue at " +
             "https://github.com/bazelbuild/apple_support/issues with the following:\n" +
             error_msg)

    repository_ctx.file(output, result.stdout)

def _copy_file(repository_ctx, src, dest):
    repository_ctx.file(dest, content = repository_ctx.read(src))

def configure_osx_toolchain(repository_ctx):
    """Configure C++ toolchain on macOS.

    Args:
      repository_ctx: The repository context.

    Returns:
      Whether or not configuration was successful
    """

    # All Label resolutions done at the top of the function to avoid issues
    # with starlark function restarts, see this:
    # https://github.com/bazelbuild/bazel/blob/ab71a1002c9c53a8061336e40f91204a2a32c38e/tools/cpp/lib_cc_configure.bzl#L17-L38
    # for more info
    xcode_locator = Label("@bazel_tools//tools/osx:xcode_locator.m")
    cc_wrapper_template = Label("@build_bazel_apple_support//crosstool:osx_cc_wrapper.sh.tpl")
    xcrunwrapper = Label("@build_bazel_apple_support//crosstool:xcrunwrapper.sh")
    libtool_template = Label("@build_bazel_apple_support//crosstool:libtool.sh.tpl")
    make_hashed_objlist = Label("@build_bazel_apple_support//crosstool:make_hashed_objlist.py")
    cc_toolchain_config = Label("@build_bazel_apple_support//crosstool:cc_toolchain_config.bzl")
    universal_exec_tool = Label("@build_bazel_apple_support//crosstool:universal_exec_tool.bzl")
    build_template = Label("@build_bazel_apple_support//crosstool:BUILD.tpl")
    libtool_check_unique_src_path = str(repository_ctx.path(
        Label("@build_bazel_apple_support//crosstool:libtool_check_unique.cc"),
    ))
    wrapped_clang_src_path = str(repository_ctx.path(
        Label("@build_bazel_apple_support//crosstool:wrapped_clang.cc"),
    ))
    generate_modulemap_path = str(repository_ctx.path(
        Label("@build_bazel_apple_support//crosstool:generate-modulemap.sh"),
    ))

    xcode_toolchains = []
    xcodeloc_err = ""
    allow_non_applications_xcode = "BAZEL_ALLOW_NON_APPLICATIONS_XCODE" in repository_ctx.os.environ and repository_ctx.os.environ["BAZEL_ALLOW_NON_APPLICATIONS_XCODE"] == "1"
    if allow_non_applications_xcode:
        (xcode_toolchains, xcodeloc_err) = run_xcode_locator(repository_ctx, xcode_locator)
        if not xcode_toolchains:
            return False, xcodeloc_err

    # For Xcode toolchains, there's no reason to use anything other than
    # wrapped_clang, so that we still get the Bazel Xcode placeholder
    # substitution and other behavior for actions that invoke this
    # cc_wrapper.sh script. The wrapped_clang binary is already hardcoded
    # into the Objective-C crosstool actions, anyway, so this ensures that
    # the C++ actions behave consistently.
    _copy_file(repository_ctx, cc_wrapper_template, "cc_wrapper.sh.tpl")
    _copy_file(repository_ctx, xcrunwrapper, "xcrunwrapper.sh")
    _copy_file(repository_ctx, libtool_template, "libtool.sh.tpl")
    _copy_file(repository_ctx, make_hashed_objlist, "make_hashed_objlist.py")
    _copy_file(repository_ctx, cc_toolchain_config, "cc_toolchain_config.bzl")
    _copy_file(repository_ctx, universal_exec_tool, "universal_exec_tool.bzl")
    _copy_file(repository_ctx, libtool_check_unique_src_path, "libtool_check_unique.cc")
    _copy_file(repository_ctx, wrapped_clang_src_path, "wrapped_clang.cc")

    layering_check_modulemap = None
    if repository_ctx.os.environ.get("APPLE_SUPPORT_LAYERING_CHECK_BETA") == "1":
        layering_check_modulemap = "layering_check.modulemap"
        _generate_system_modulemap(repository_ctx, generate_modulemap_path, layering_check_modulemap)
        repository_ctx.file(
            "module.modulemap",
            "// Placeholder to satisfy API requirements. See apple_support for usage",
        )

    tool_paths = {}
    gcov_path = repository_ctx.os.environ.get("GCOV")
    if gcov_path != None:
        if not gcov_path.startswith("/"):
            gcov_path = repository_ctx.which(gcov_path)
        tool_paths["gcov"] = gcov_path

    features = []
    if _succeeds(repository_ctx, "ld", "-no_warn_duplicate_libraries", "-v"):
        features.append("no_warn_duplicate_libraries")

    escaped_include_paths = _get_escaped_xcode_cxx_inc_directories(repository_ctx, xcode_toolchains)
    escaped_cxx_include_directories = []
    for path in escaped_include_paths:
        escaped_cxx_include_directories.append(("            \"%s\"," % path))
    if xcodeloc_err:
        escaped_cxx_include_directories.append("            # Error: " + xcodeloc_err)
    repository_ctx.template(
        "BUILD",
        build_template,
        {
            "%{cxx_builtin_include_directories}": "\n".join(escaped_cxx_include_directories),
            "%{features}": "\n".join(['"{}"'.format(x) for x in features]),
            "%{layering_check_modulemap}": "\":{}\",".format(layering_check_modulemap) if layering_check_modulemap else "",
            "%{placeholder_modulemap}": "\":module.modulemap\"" if layering_check_modulemap else "None",
            "%{tool_paths_overrides}": ",\n            ".join(
                ['"%s": "%s"' % (k, v) for k, v in tool_paths.items()],
            ),
        },
    )

    return True, ""
