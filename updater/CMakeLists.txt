cmake_minimum_required(VERSION 3.16)
project(StevedoreUpdater LANGUAGES OBJC)
find_package(MavericksShipyard REQUIRED)
include(Mavericks)
include(MavericksSparkle)
get_filename_component(STEVEDORE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
if(NOT EXISTS "${STEVEDORE_ROOT}/VERSION")
  message(FATAL_ERROR "no ${STEVEDORE_ROOT}/VERSION: the release workflow's ver job writes it, from shipyard's self-upstream-version.sh")
endif()
file(STRINGS "${STEVEDORE_ROOT}/VERSION" STEVEDORE_VERSION LIMIT_COUNT 1)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${STEVEDORE_ROOT}/VERSION")
# spec: updater/ICON-CREDIT.txt -- the generic icon on purpose, with the reason and the exit
mavericks_add_updater_app(
  PRODUCT stevedore
  PRODUCT_NAME "Mavericks stevedore"
  VERSION "${STEVEDORE_VERSION}"
  ED_PUBKEY_FILE "${CMAKE_CURRENT_SOURCE_DIR}/ed25519_key.pub"
  LOG_PREFIX "MavStevedoreUpdater"
  CONFIRM_TITLE "Mavericks stevedore updated"
  CONFIRM_BODY "stevedore for Mavericks in /usr/local/mavergreen/stevedore was updated."
  ALLOW_GENERIC
)
