# Copyright (C) 2022 The Qt Company Ltd.
# SPDX-License-Identifier: BSD-3-Clause

#####################################################################
## tst_qdialogbuttonbox Test:
#####################################################################

qt_internal_add_test(tst_qdialogbuttonbox
    SOURCES
        tst_qdialogbuttonbox.cpp
    LIBRARIES
        Qt::Gui
        Qt::Widgets
        Qt::WidgetsPrivate
)
