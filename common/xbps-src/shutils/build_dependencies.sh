# vim: set ts=4 sw=4 et:
#
# Install a required package dependency, like:
#
#	xbps-install -Ay <pkgname>
#
# Returns 0 if package already installed or installed successfully.
# Any other error number otherwise.
#
install_pkg_from_repos() {
    local pkg="$1" cross="$2" rval= tmplogf=

    tmplogf=$(mktemp)
    if [ -n "$cross" ]; then
        $FAKEROOT_CMD $XBPS_INSTALL_XCMD -Ayd "$pkg" >$tmplogf 2>&1
    else
        if [ -z "$CHROOT_READY" ]; then
            $XBPS_INSTALL_CMD -Ayd "$pkg" >$tmplogf 2>&1
        else
            $FAKEROOT_CMD $XBPS_INSTALL_CMD -Ayd "$pkg" >$tmplogf 2>&1
        fi
    fi
    rval=$?
    if [ $rval -ne 0 -a $rval -ne 17 ]; then
        # xbps-install can return:
        #
        # SUCCESS  (0): package installed successfully.
        # ENOENT   (2): package missing in repositories.
        # ENXIO    (6): package depends on invalid dependencies.
        # EEXIST  (17): package already installed.
        # ENODEV  (19): package depends on missing dependencies.
        # ENOTSUP (95): no repositories registered.
        #
        [ -z "$XBPS_KEEP_ALL" ] && remove_pkg_autodeps
        msg_red "$pkgver: failed to install '$1' dependency! (error $rval)\n"
        cat $tmplogf && rm -f $tmplogf
        msg_error "Please see above for the real error, exiting...\n"
    fi
    rm -f $tmplogf
    [ $rval -eq 17 ] && rval=0
    return $rval
}

#
# Returns 0 if pkgpattern in $1 is matched against current installed
# package, 1 if no match and 2 if not installed.
#
check_pkgdep_matched() {
    local pkg="$1" cross="$2" uhelper= pkgn= iver=

    [ "$build_style" = "meta" ] && return 2
    [ -z "$pkg" ] && return 255

    pkgn="$($XBPS_UHELPER_CMD getpkgdepname ${pkg})"
    if [ -z "$pkgn" ]; then
        pkgn="$($XBPS_UHELPER_CMD getpkgname ${pkg})"
    fi
    [ -z "$pkgn" ] && return 255

    if [ -n "$cross" ]; then
        uhelper="$XBPS_UHELPER_XCMD"
    else
        uhelper="$XBPS_UHELPER_CMD"
    fi

    iver="$($uhelper version $pkgn)"
    if [ $? -eq 0 -a -n "$iver" ]; then
        $XBPS_UHELPER_CMD pkgmatch "${pkgn}-${iver}" "${pkg}"
        [ $? -eq 1 ] && return 0
    else
        return 2
    fi

    return 1
}

#
# Returns 0 if pkgpattern in $1 is installed and greater than current
# installed package, otherwise 1.
#
check_installed_pkg() {
    local pkg="$1" cross="$2" uhelper= pkgn= iver=

    [ -z "$pkg" ] && return 2

    pkgn="$($XBPS_UHELPER_CMD getpkgname ${pkg})"
    [ -z "$pkgn" ] && return 2

    if [ -n "$cross" ]; then
        uhelper="$XBPS_UHELPER_XCMD"
    else
        uhelper="$XBPS_UHELPER_CMD"
    fi

    iver="$($uhelper version $pkgn)"
    if [ $? -eq 0 -a -n "$iver" ]; then
        $XBPS_CMPVER_CMD "${pkgn}-${iver}" "${pkg}"
        [ $? -eq 0 -o $? -eq 1 ] && return 0
    fi

    return 1
}

#
# Installs all dependencies required by a package.
#
install_pkg_deps() {
    local pkg="$1" cross="$2" rval _realpkg curpkgdepname pkgn iver _props _exact
    local i j found rundep

    local -a host_binpkg_deps binpkg_deps
    local -a host_missing_deps missing_deps

    [ -z "$pkgname" ] && return 2

    setup_pkg_depends

    if [ -z "$build_depends" -a -z "$host_build_depends" -a -z "$run_depends" ]; then
        return 0
    fi

    msg_normal "$pkgver: required dependencies:\n"

    #
    # Host build dependencies.
    #
    for i in ${host_build_depends}; do
        _realpkg="${i%\?*}"
        pkgn=$($XBPS_UHELPER_CMD getpkgdepname "${_realpkg}")
        if [ -z "$pkgn" ]; then
            pkgn=$($XBPS_UHELPER_CMD getpkgname "${_realpkg}")
            if [ -z "$pkgn" ]; then
                msg_error "$pkgver: invalid build dependency: ${i}\n"
            fi
            _exact=1
        fi
        check_pkgdep_matched "${_realpkg}"
        local rval=$?
        if [ $rval -eq 0 ]; then
            iver=$($XBPS_UHELPER_CMD version "${pkgn}")
            if [ $? -eq 0 -a -n "$iver" ]; then
                echo "   [host] ${_realpkg}: found '$pkgn-$iver'."
                continue
            fi
        elif [ $rval -eq 1 ]; then
            iver=$($XBPS_UHELPER_CMD version "${pkgn}")
            if [ $? -eq 0 -a -n "$iver" ]; then
                echo "   [host] ${_realpkg}: installed ${iver} (unresolved) removing..."
                $FAKEROOT_CMD $XBPS_REMOVE_CMD -iyf $pkgn >/dev/null 2>&1
            fi
        else
            if [ -n "${_exact}" ]; then
                unset _exact
                _props=$($XBPS_QUERY_CMD -R -ppkgver,repository "${pkgn}" 2>/dev/null)
            else
                _props=$($XBPS_QUERY_CMD -R -ppkgver,repository "${_realpkg}" 2>/dev/null)
            fi
            if [ -n "${_props}" ]; then
                set -- ${_props}
                $XBPS_UHELPER_CMD pkgmatch ${1} "${_realpkg}"
                if [ $? -eq 1 ]; then
                    echo "   [host] ${_realpkg}: found $1 in $2."
                    host_binpkg_deps+=("$1")
                    shift 2
                    continue
                else
                    echo "   [host] ${_realpkg}: not found."
                fi
                shift 2
            else
                echo "   [host] ${_realpkg}: not found."
            fi
        fi
        host_missing_deps+=("${_realpkg}")
    done

    #
    # Target build dependencies.
    #
    for i in ${build_depends} ${run_depends}; do
        _realpkg="${i%\?*}"
        pkgn=$($XBPS_UHELPER_CMD getpkgdepname "${_realpkg}")
        if [ -z "$pkgn" ]; then
            pkgn=$($XBPS_UHELPER_CMD getpkgname "${_realpkg}")
            if [ -z "$pkgn" ]; then
                msg_error "$pkgver: invalid build dependency: ${_realpkg}\n"
            fi
            _exact=1
        fi
        # Check if dependency is a subpkg, if it is, ignore it.
        unset found
        for j in ${subpackages}; do
            [ "$j" = "$pkgn" ] && found=1 && break
        done
        [ -n "$found" ] && continue
        # Check if it's a runtime dependency.
        unset rundep
        for j in ${run_depends}; do
            [ "$j" = "$i" ] && rundep="runtime" && break
        done
        check_pkgdep_matched "${_realpkg}" $cross
        local rval=$?
        if [ $rval -eq 0 ]; then
            iver=$($XBPS_UHELPER_XCMD version "${pkgn}")
            if [ $? -eq 0 -a -n "$iver" ]; then
                echo "   [${rundep:-target}] ${_realpkg}: found '$pkgn-$iver'."
                continue
            fi
        elif [ $rval -eq 1 ]; then
            iver=$($XBPS_UHELPER_XCMD version "${pkgn}")
            if [ $? -eq 0 -a -n "$iver" ]; then
                echo "   [${rundep:-target}] ${_realpkg}: installed ${iver} (unresolved) removing..."
                $XBPS_REMOVE_XCMD -iyf $pkgn >/dev/null 2>&1
            fi
        else
            if [ -n "${_exact}" ]; then
                unset _exact
                _props=$($XBPS_QUERY_XCMD -R -ppkgver,repository "${pkgn}" 2>/dev/null)
            else
                _props=$($XBPS_QUERY_XCMD -R -ppkgver,repository "${_realpkg}" 2>/dev/null)
            fi
            if [ -n "${_props}" ]; then
                set -- ${_props}
                $XBPS_UHELPER_CMD pkgmatch ${1} "${_realpkg}"
                if [ $? -eq 1 ]; then
                    # If dependency is part of run_depends just check if the binpkg has
                    # been created, but don't install it.
                    if [ -z "$rundep" ]; then
                        binpkg_deps+=("$1")
                    fi
                    echo "   [${rundep:-target}] ${_realpkg}: found $1 in $2."
                    shift 2
                    continue
                else
                    echo "   [${rundep:-target}] ${_realpkg}: not found."
                fi
                shift 2
            else
                echo "   [${rundep:-target}] ${_realpkg}: not found."
            fi
        fi
        missing_deps+=("${_realpkg}")
    done

    # Host missing dependencies, build from srcpkgs.
    for i in ${host_missing_deps[@]}; do
        curpkgdepname=$($XBPS_UHELPER_CMD getpkgdepname "$i")
        setup_pkg $curpkgdepname
        ${XBPS_UHELPER_CMD} pkgmatch "$pkgver" "$i"
        if [ $? -eq 0 ]; then
            setup_pkg $XBPS_TARGET_PKG
            msg_error "$pkgver: required host dependency '$i' cannot be resolved!\n"
        fi
        install_pkg full
        setup_pkg $XBPS_TARGET_PKG $XBPS_CROSS_BUILD
        install_pkg_deps $sourcepkg $XBPS_CROSS_BUILD
    done

    # Target missing dependencies, build from srcpkgs.
    for i in ${missing_deps[@]}; do
        # packages not found in repos, install from source.
        curpkgdepname=$($XBPS_UHELPER_CMD getpkgdepname "$i")
        setup_pkg $curpkgdepname $cross
        # Check if version in srcpkg satisfied required dependency,
        # and bail out if doesn't.
        $XBPS_UHELPER_CMD pkgmatch "$pkgver" "$i"
        if [ $? -eq 0 ]; then
            setup_pkg $XBPS_TARGET_PKG $cross
            msg_error "$pkgver: required target dependency '$i' cannot be resolved!\n"
        fi
        install_pkg full $cross
        setup_pkg $XBPS_TARGET_PKG $XBPS_CROSS_BUILD
        install_pkg_deps $sourcepkg $XBPS_CROSS_BUILD
    done

    if [ "$TARGETPKG_PKGDEPS_DONE" ]; then
        return 0
    fi

    for i in ${host_binpkg_deps[@]}; do
        msg_normal "$pkgver: installing host dependency '$i' ...\n"
        install_pkg_from_repos "${i}"
    done

    for i in ${binpkg_deps[@]}; do
        if [ -n "$CHROOT_READY" -a "$build_style" = "meta" ]; then
            continue
        fi
        msg_normal "$pkgver: installing target dependency '$i' ...\n"
        install_pkg_from_repos "$i" $cross
    done

    if [ "$XBPS_TARGET_PKG" = "$sourcepkg" ]; then
        TARGETPKG_PKGDEPS_DONE=1
    fi
}
