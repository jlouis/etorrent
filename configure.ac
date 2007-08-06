AC_INIT(erlang torrent client, 1.0, jesper.louis.andersen@gmail.com, etorrent)
AC_COPYRIGHT(Copyright (C) 2007 Jesper Louis Andersen)

dnl require autoconf version >=2.59c, first one with erlang macros
AC_PREREQ(2.59c)

dnl Erlang-related config
AC_ERLANG_SUBST_ROOT_DIR
AC_ERLANG_SUBST_LIB_DIR
AC_ERLANG_SUBST_INSTALL_LIB_SUBDIR(AC_PACKAGE_TARNAME, AC_PACKAGE_VERSION)

AC_ERLANG_NEED_ERLC
AC_ERLANG_NEED_ERL

dnl Generic configuration
AC_PROG_INSTALL
AC_PROG_MKDIR_P
AC_PROG_LN_S

AC_OUTPUT(Makefile doc/Makefile)

