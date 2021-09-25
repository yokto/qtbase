/****************************************************************************
**
** Copyright (C) 2016 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the QtCore module of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see https://www.qt.io/terms-conditions. For further
** information use the contact form at https://www.qt.io/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 3 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL3 included in the
** packaging of this file. Please review the following information to
** ensure the GNU Lesser General Public License version 3 requirements
** will be met: https://www.gnu.org/licenses/lgpl-3.0.html.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 2.0 or (at your option) the GNU General
** Public license version 3 or any later version approved by the KDE Free
** Qt Foundation. The licenses are as published by the Free Software
** Foundation and appearing in the file LICENSE.GPL2 and LICENSE.GPL3
** included in the packaging of this file. Please review the following
** information to ensure the GNU General Public License requirements will
** be met: https://www.gnu.org/licenses/gpl-2.0.html and
** https://www.gnu.org/licenses/gpl-3.0.html.
**
** $QT_END_LICENSE$
**
****************************************************************************/

#include "qelfparser_p.h"

#if defined (Q_OF_ELF) && defined(Q_CC_GNU)

#include "qlibrary_p.h"
#include <qdebug.h>

QT_BEGIN_NAMESPACE

// #define QELFPARSER_DEBUG 1

const char *QElfParser::parseSectionHeader(const char *data, ElfSectionHeader *sh)
{
    sh->name = qFromUnaligned<qelfword_t>(data);
    data += sizeof(qelfword_t); // sh_name
    sh->type = qFromUnaligned<qelfword_t>(data);
    data += sizeof(qelfword_t)  // sh_type
         + sizeof(qelfaddr_t)   // sh_flags
         + sizeof(qelfaddr_t);  // sh_addr
    sh->offset = qFromUnaligned<qelfoff_t>(data);
    data += sizeof(qelfoff_t);  // sh_offset
    sh->size = qFromUnaligned<qelfoff_t>(data);
    data += sizeof(qelfoff_t);  // sh_size
    return data;
}

QLibraryScanResult QElfParser::parse(const char *dataStart, ulong fdlen, QString *errMsg)
{
#if defined(QELFPARSER_DEBUG)
    qDebug() << "QElfParser::parse " << library;
#endif

    if (fdlen < 64) {
        *errMsg = QLibrary::tr("'%1' is not an ELF object (%2)").arg(*errMsg, QLibrary::tr("file too small"));
        return {};
    }
    const char *data = dataStart;
    if (qstrncmp(data, "\177ELF", 4) != 0) {
        *errMsg = QLibrary::tr("'%1' is not an ELF object").arg(*errMsg);
        return {};
    }
    // 32 or 64 bit
    if (data[4] != 1 && data[4] != 2) {
        *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)").arg(*errMsg, QLibrary::tr("odd cpu architecture"));
        return {};
    }

    /*  If you remove this check, to read ELF objects of a different arch, please make sure you modify the typedefs
        to match the _plugin_ architecture.
    */
    constexpr int ExpectedClass = (sizeof(void *) == 4) ? 1 : 2;
    if (data[4] != ExpectedClass) {
        *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)").arg(*errMsg, QLibrary::tr("wrong cpu architecture"));
        return {};
    }

    // endian
    constexpr int ExpectedEndianness = (Q_BYTE_ORDER == Q_LITTLE_ENDIAN) ? 1 : 2;
    if (data[5] != ExpectedEndianness) {
        *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)").arg(*errMsg, QLibrary::tr("odd endianness"));
        return {};
    }

    data += 16                  // e_ident
         +  sizeof(qelfhalf_t)  // e_type
         +  sizeof(qelfhalf_t)  // e_machine
         +  sizeof(qelfword_t)  // e_version
         +  sizeof(qelfaddr_t)  // e_entry
         +  sizeof(qelfoff_t);  // e_phoff

    qelfoff_t e_shoff = qFromUnaligned<qelfoff_t> (data);
    data += sizeof(qelfoff_t)    // e_shoff
         +  sizeof(qelfword_t);  // e_flags

    qelfhalf_t e_shsize = qFromUnaligned<qelfhalf_t> (data);

    if (e_shsize > fdlen) {
        *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)").arg(*errMsg, QLibrary::tr("unexpected e_shsize"));
        return {};
    }

    data += sizeof(qelfhalf_t)  // e_ehsize
         +  sizeof(qelfhalf_t)  // e_phentsize
         +  sizeof(qelfhalf_t); // e_phnum

    qelfhalf_t e_shentsize = qFromUnaligned<qelfhalf_t> (data);

    if (e_shentsize % 4) {
        *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)").arg(*errMsg, QLibrary::tr("unexpected e_shentsize"));
        return {};
    }
    data += sizeof(qelfhalf_t); // e_shentsize
    qelfhalf_t e_shnum     = qFromUnaligned<qelfhalf_t> (data);
    data += sizeof(qelfhalf_t); // e_shnum
    qelfhalf_t e_shtrndx   = qFromUnaligned<qelfhalf_t> (data);
    data += sizeof(qelfhalf_t); // e_shtrndx

    if ((quint32)(e_shnum * e_shentsize) > fdlen) {
            const QString message =
                QLibrary::tr("announced %n section(s), each %1 byte(s), exceed file size",
                             nullptr, int(e_shnum)).arg(e_shentsize);
        *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)").arg(*errMsg, message);
        return {};
    }

#if defined(QELFPARSER_DEBUG)
    qDebug() << e_shnum << "sections starting at " << ("0x" + QByteArray::number(e_shoff, 16)).data() << "each" << e_shentsize << "bytes";
#endif

    ElfSectionHeader strtab;
    qulonglong soff = e_shoff + qelfword_t(e_shentsize) * qelfword_t(e_shtrndx);

    if ((soff + e_shentsize) > fdlen || soff % 4 || soff == 0) {
        *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)")
                               .arg(*errMsg, QLibrary::tr("shstrtab section header seems to be at %1")
                                             .arg(QString::number(soff, 16)));
        return {};
    }

    parseSectionHeader(dataStart + soff, &strtab);
    m_stringTableFileOffset = strtab.offset;

    if ((quint32)(strtab.offset + strtab.size) > fdlen || strtab.offset == 0) {
        *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)")
                               .arg(*errMsg, QLibrary::tr("string table seems to be at %1")
                                             .arg(QString::number(strtab.offset, 16)));
        return {};
    }

#if defined(QELFPARSER_DEBUG)
    qDebug(".shstrtab at 0x%s", QByteArray::number(m_stringTableFileOffset, 16).data());
#endif

    const char *s = dataStart + e_shoff;
    for (int i = 0; i < e_shnum; ++i) {
        ElfSectionHeader sh;
        parseSectionHeader(s, &sh);
        if (sh.name == 0) {
            s += e_shentsize;
            continue;
        }
        const char *shnam = dataStart + m_stringTableFileOffset + sh.name;

        if (m_stringTableFileOffset + sh.name > fdlen) {
            *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)")
                    .arg(*errMsg, QLibrary::tr("section name %1 of %2 behind end of file")
                                  .arg(i).arg(e_shnum));
            return {};
        }

#if defined(QELFPARSER_DEBUG)
        qDebug() << "++++" << i << shnam;
#endif

        if (qstrcmp(shnam, ".qtmetadata") == 0 ) {
            if (!(sh.type & 0x1)) {
                if (shnam[1] == 'r') {
                    *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)")
                            .arg(*errMsg, QLibrary::tr("empty .rodata. not a library."));
                    return {};
                }
#if defined(QELFPARSER_DEBUG)
                qDebug()<<"section is not program data. skipped.";
#endif
                s += e_shentsize;
                continue;
            }

            if (sh.offset == 0 || (sh.offset + sh.size) > fdlen || sh.size < 1) {
                *errMsg = QLibrary::tr("'%1' is an invalid ELF object (%2)")
                        .arg(*errMsg, QLibrary::tr("missing section data. This is not a library."));
                return {};
            }
            return { qsizetype(sh.offset), qsizetype(sh.size) };
        }
        s += e_shentsize;
    }
    return {};
}

QT_END_NAMESPACE

#endif // defined(Q_OF_ELF) && defined(Q_CC_GNU)
