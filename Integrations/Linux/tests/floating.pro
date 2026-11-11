QT += core gui widgets qml network dbus testlib
CONFIG += c++17 testcase console
CONFIG -= app_bundle
TARGET = tst_floating
SOURCES += tst_floating.cpp ../DesktopController.cpp
HEADERS += ../DesktopController.h ../FloatingMenu.h
RESOURCES += ../desktop.qrc