QT += core gui widgets quick qml quickcontrols2 network dbus
CONFIG += c++17 console
CONFIG -= app_bundle
TARGET = codexbar-linux
SOURCES += main.cpp DesktopController.cpp
HEADERS += DesktopController.h
RESOURCES += desktop.qrc
QMAKE_CXXFLAGS += -Wall -Wextra
target.path = $$PREFIX/bin
isEmpty(PREFIX): target.path = /usr/local/bin
INSTALLS += target

DESKTOP_VERSION = $$(CODEXBAR_DESKTOP_VERSION)
isEmpty(DESKTOP_VERSION): DESKTOP_VERSION = 0.1.0
DEFINES += CODEXBAR_DESKTOP_VERSION=\\\"$$DESKTOP_VERSION\\\"
