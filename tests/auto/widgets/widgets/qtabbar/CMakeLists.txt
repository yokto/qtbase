# Copyright (C) 2022 The Qt Company Ltd.
# SPDX-License-Identifier: BSD-3-Clause

#####################################################################
## tst_qtabbar Test:
#####################################################################

qt_internal_add_test(tst_qtabbar
    SOURCES
        tst_qtabbar.cpp
    LIBRARIES
        Qt::Gui
        Qt::Widgets
        Qt::WidgetsPrivate
)
