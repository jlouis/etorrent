AC_INIT(erlang torrent client, 0.1, jesper.louis.andersen@gmail.com, etorrent)
AC_COPYRIGHT(Copyright (C) 2007 Jesper Louis Andersen)

dnl require autoconf version >=2.59c, first one with erlang macros
AC_PREREQ(2.59c)

dnl require a recent automake
AM_INIT_AUTOMAKE(1.9.5)

dnl Erlang-related config
AC_ERLANG_SUBST_ROOT_DIR
AC_ERLANG_SUBST_LIB_DIR
AC_ERLANG_SUBST_INSTALL_LIB_SUBDIR(AC_PACKAGE_TARNAME, 1.0)

AC_ERLANG_NEED_ERLC

erlcflags="+debug_info"

AC_SUBST([ERLCFLAGS], [$erlcflags])

AC_ERLANG_SUBST_INSTALL_LIB_SUBDIR(etorrent, 1.0)

AC_OUTPUT(Makefile lib/Makefile lib/etorrent-1.0/Makefile lib/etorrent-1.0/src/Makefile releases/Makefile releases/1.0/Makefile)

