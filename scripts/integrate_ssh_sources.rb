#!/usr/bin/env ruby

require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "ioassh.xcodeproj")

def sources_from_cmake_set(path, variable)
  contents = File.read(path)
  body = contents.match(/set\(#{Regexp.escape(variable)}\s+(.*?)^\)/m)&.captures&.first
  raise "Could not find #{variable} in #{path}" unless body

  body.scan(/^\s*([A-Za-z0-9_.\/-]+\.c)\s*$/).flatten
end

def add_sources(target, group, paths)
  paths.each do |path|
    absolute = File.expand_path(path, group.real_path)
    raise "Missing source: #{absolute}" unless File.file?(absolute)

    reference = group.find_file_by_path(path) || group.new_file(path)
    target.source_build_phase.add_file_reference(reference, true)
  end
end

def configure_vendor_target(target, header_paths)
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings["CLANG_ENABLE_MODULES"] = "NO"
    settings["CODE_SIGNING_ALLOWED"] = "NO"
    settings["GCC_C_LANGUAGE_STANDARD"] = "gnu17"
    settings["GCC_PREPROCESSOR_DEFINITIONS"] = [
      "$(inherited)",
      "MBEDTLS_THREADING_C=1",
      "MBEDTLS_THREADING_PTHREAD=1"
    ]
    settings["GCC_TREAT_WARNINGS_AS_ERRORS"] = "NO"
    settings["HEADER_SEARCH_PATHS"] = ["$(inherited)", *header_paths]
    settings["IPHONEOS_DEPLOYMENT_TARGET"] = "18.5"
    settings["MACOSX_DEPLOYMENT_TARGET"] = "15.5"
    settings["ONLY_ACTIVE_ARCH"] = "YES"
    settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
    settings["SDKROOT"] = "auto"
    settings["SKIP_INSTALL"] = "YES"
    settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator macosx xros xrsimulator"
    settings["XROS_DEPLOYMENT_TARGET"] = "2.5"
  end
end

project = Xcodeproj::Project.open(PROJECT_PATH)
app = project.targets.find { |target| target.name == "ioassh" }
raise "ioassh target not found" unless app
raise "MbedCrypto target already exists" if project.targets.any? { |target| target.name == "MbedCrypto" }
raise "LibSSH target already exists" if project.targets.any? { |target| target.name == "LibSSH" }

vendor_group = project.main_group.find_subpath("Vendor", true)
vendor_group.set_source_tree("<group>")
vendor_group.set_path("Vendor")
mbedtls_group = vendor_group.new_group("mbedtls", "mbedtls")
libssh_group = vendor_group.new_group("libssh", "libssh")

mbedcrypto = project.new_target(:static_library, "MbedCrypto", :ios, "18.5")
mbed_sources = sources_from_cmake_set(
  File.join(ROOT, "Vendor/mbedtls/library/CMakeLists.txt"),
  "src_crypto"
).map { |source| "library/#{source}" }
mbed_sources.concat(%w[
  3rdparty/everest/library/everest.c
  3rdparty/everest/library/x25519.c
  3rdparty/everest/library/Hacl_Curve25519_joined.c
  3rdparty/p256-m/p256-m_driver_entrypoints.c
  3rdparty/p256-m/p256-m/p256-m.c
])
add_sources(mbedcrypto, mbedtls_group, mbed_sources)
configure_vendor_target(mbedcrypto, %w[
  $(SRCROOT)/Vendor/mbedtls/include
  $(SRCROOT)/Vendor/mbedtls/library
  $(SRCROOT)/Vendor/mbedtls/3rdparty/everest/include
  $(SRCROOT)/Vendor/mbedtls/3rdparty/everest/include/everest
  $(SRCROOT)/Vendor/mbedtls/3rdparty/p256-m
  $(SRCROOT)/Vendor/mbedtls/3rdparty/p256-m/p256-m
])

libssh = project.new_target(:static_library, "LibSSH", :ios, "18.5")
libssh_sources = sources_from_cmake_set(
  File.join(ROOT, "Vendor/libssh/src/CMakeLists.txt"),
  "libssh_SRCS"
)
libssh_sources.concat(%w[
  threads/noop.c
  threads/pthread.c
  threads/mbedtls.c
  libmbedcrypto.c
  mbedcrypto_missing.c
  pki_mbedcrypto.c
  ecdh_mbedcrypto.c
  getrandom_mbedcrypto.c
  md_mbedcrypto.c
  dh_key.c
  pki_ed25519.c
  external/ed25519.c
  external/fe25519.c
  external/ge25519.c
  external/sc25519.c
  external/sntrup761.c
  external/chacha.c
  external/poly1305.c
  chachapoly.c
  curve25519_mbedcrypto.c
  dh-gex.c
  mlkem_native.c
  external/libcrux_mlkem768_sha3.c
])
libssh_sources = libssh_sources.uniq.map { |source| "src/#{source}" }
add_sources(libssh, libssh_group, libssh_sources)
configure_vendor_target(libssh, %w[
  $(SRCROOT)/Vendor/apple-config
  $(SRCROOT)/Vendor/apple-config/include
  $(SRCROOT)/Vendor/libssh/include
  $(SRCROOT)/Vendor/libssh/src
  $(SRCROOT)/Vendor/mbedtls/include
  $(SRCROOT)/Vendor/mbedtls/library
])

libssh.add_dependency(mbedcrypto)
app.add_dependency(mbedcrypto)
app.add_dependency(libssh)
app.frameworks_build_phase.add_file_reference(mbedcrypto.product_reference, true)
app.frameworks_build_phase.add_file_reference(libssh.product_reference, true)

app.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["HEADER_SEARCH_PATHS"] = [
    "$(inherited)",
    "$(SRCROOT)/Vendor/apple-config/include",
    "$(SRCROOT)/Vendor/libssh/include"
  ]
  settings["SWIFT_OBJC_BRIDGING_HEADER"] = "ioassh/ioassh-Bridging-Header.h"
end

project.save
puts "Integrated #{mbed_sources.length} Mbed TLS and #{libssh_sources.length} libssh C sources."
