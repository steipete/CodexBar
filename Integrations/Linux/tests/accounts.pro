QT += core gui qml network dbus testlib
CONFIG += c++17 testcase console
CONFIG -= app_bundle
TARGET = tst_accounts
SOURCES += tst_accounts.cpp ../DesktopController.cpp
HEADERS += ../DesktopController.h
RESOURCES += ../desktop.qrc
