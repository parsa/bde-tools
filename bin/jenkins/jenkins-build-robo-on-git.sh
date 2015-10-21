#!/opt/bb/bin/bash

if [[ -z "$WORKSPACE" ]]
then \
    echo Must specify WORKSPACE environment variable
    exit 1
fi

ROOT_LOCATION=/bb/bde/bdebuild/jenkins

LOG_LOCATION=${ROOT_LOCATION}/logs
export LOG_LOCATION
mkdir -p $LOG_LOCATION

LOGFILE=$LOG_LOCATION/log-$(/opt/bb/bin/date +"%Y%m%d-%H%M%S")-$(hostname)-$$.txt

# Redundant in case exec &>... fails for some reason
echo Logging to $LOGFILE

# This redirects both STDOUT and STDERR (&>) into a subshell (with >() ) where
# each line is prefixed with the timestamp and then sent via tee into both the
# $LOGFILE file and the screen.
exec &> >(/opt/bb/bin/perl -MPOSIX=strftime \
            -ne'BEGIN{$|++} \
                printf "%s: %s",(strftime("%Y%m%d-%H%M%S", localtime)), $_' \
        | /opt/bb/bin/tee -a $LOGFILE)

DPKG_LOCATION=${WORKSPACE}/dpkg-$$
export DPKG_LOCATION
mkdir -p $DPKG_LOCATION

echo Logging to $LOGFILE
echo Operating in WORKSPACE $WORKSPACE and DPKG_LOCATION $DPKG_LOCATION

RETRY="$WORKSPACE/source/bde-tools/bin/retry -v -x nonzero -a 3 -p 60 -t 0 -- "

cd "$DPKG_LOCATION"

if [ $? -ne 0 ]
then \
    echo FATAL: Unable to cd into $DPKG_LOCATION
    exit 1
fi

echo Setting up PATH for dpkg

#START Copied from devgit:deveng/chimera contrib/dpkg

# Enable PATH settings required for the use of the dpkg framework.
# See https://cms.prod.bloomberg.com/team/display/sb/DPKG for details.
# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
if test -d /opt/swt/bin
then
    for OVERRIDE in \
        /opt/swt/bin/readlink /opt/swt/bin/tar /opt/swt/bin/gmake \
        /opt/swt/bin/find
    do
        PATH=$(/usr/bin/dirname $(/opt/swt/bin/readlink "$OVERRIDE")):$PATH
    done
    PATH=$PATH:/bbsrc/bin/builddeb/prod/bin:/bbs/bin/dpkg/bin
else
    echo "FATAL: contrib/dpkg can only be used with /opt/swt/bin present" >&2
    exit 1
fi

#END   Copied from devgit:deveng/chimera contrib/dpkg

DPKG_ARCH=$(dpkg --print-architecture)

# We need EXTRA_ARCH on non-amd platforms so "Architecture: all" packages can
# build there.
EXTRA_ARCH=""

if [ "$DPKG_ARCH" != "amd64" ]
then
    EXTRA_ARCH="--arch=amd64"
fi

echo Initializing DPKG distro for arch $(dpkg --print-architecture)
dpkg-distro-dev init --distribution=unstable             \
                     --arch=$(dpkg --print-architecture) \
                     $EXTRA_ARCH                         \
                     .

echo ====================================
echo ======= DPKG SCAN AND RMLOCK =======
echo ====================================

dpkg-distro-dev scan --rmlock

if [ $? -ne 0 ]
then \
    echo FATAL: failed dpkg-distro-dev scan --rmlock
    exit 1
fi

echo ====================================
echo ======= BDE DPKG BUILD PHASE =======
echo ====================================

for package in $WORKSPACE/source/bde-{oss-,internal-,}tools $WORKSPACE/source/bsl* $WORKSPACE/source/bde-core $WORKSPACE/source/a-cdb2 $WORKSPACE/source/bde-{bb,bdx}
do \
    echo "    ================================"
    echo "    ======= BUILDING $package"
    echo "    ================================"

    echo "       ================================="
    echo "       ====== last commit for $package"
    echo "       ================================="
    pushd $package > /dev/null 2>&1
    /opt/bb/bin/git log -1 --decorate=full
    popd > /dev/null 2>&1

    echo "       ================================="
    echo "       ====== dpkg-distro-dev build $package"
    echo "       ================================="

    time $RETRY dpkg-distro-dev build $package

    if [ $? -ne 0 ]
    then \
        echo FATAL: failure building $package
        exit 1
    fi
done

echo =========================================
echo ======= BUILDALL DPKG BUILD PHASE =======
echo =========================================

time $RETRY dpkg-distro-dev buildall -j 12 -k

# if [ $? -ne 0 ]
# then \
#     echo WARNING: Failure in buildall step, ignoring it
# fi

echo "Ignoring failure"

#BINARY_PACKAGES=$(grep -i '^Package:' source/b*/debian/control   \
#                | awk '{print $NF}'                              \
#                | sort -u                                        \
#                | grep -v 'RSSUITE'                              \
#                | perl -e'my $line=join ",", map {chomp; $_} <>;
#                          print $line,"\n"')
#dpkg-refroot-install $BINARY_PACKAGES

echo =========================================
echo ======= REFROOT-INSTALL PHASE ===========
echo =========================================

DISTRIBUTION_REFROOT=$DPKG_LOCATION/refroot/$(dpkg --print-architecture)
export DISTRIBUTION_REFROOT

echo "Y" | REFROOT=$DISTRIBUTION_REFROOT \
                  time dpkg-refroot-install --select robobuild-meta

# if [ $? -ne 0 ]
# then \
#     echo FATAL: Failure in dpkg-refroot-install step
#     exit 1
# fi


echo ================================
echo ======= ROBO BUILD PHASE =======
echo ================================

cd $WORKSPACE/robo

if [ $? -ne 0 ]
then \
    echo FATAL: could not cd in to robo subdir
    exit 1
fi

mkdir -p logs

src_root=$(pwd)/trunk build_root=$(pwd)/build \
    . /bbsrc/bin/prod/bin/build/build_env

echo "    ================================"
echo "    ======== BUILD_PREBUILD ========"
echo "    ================================"

time $RETRY /bbsrc/bin/prod/bin/build/build_prebuild

if [ $? -ne 0 ]
then \
    echo FATAL: build_prebuild failed
    exit 1
fi


echo "    ================================"
echo "    ======== ROBO LIB BUILD ========"
echo "    ================================"

mkdir -p build
cd       build

mkdir -p logs

ROBOLOG=logs/build.$(hostname).$(date +"%Y%m%d-%H%M%S").log

DPKG_DISTRIBUTION="unstable --distro-override=\"$DPKG_LOCATION\"/"      \
    time /opt/swt/install/make-3.82/bin/make --no-print-directory -j20 -k \
    -f ../trunk/etc/buildlibs.mk INSTALLLIBDIR=$(pwd)/lib/              \
    TARGET=install robo_prebuild_libs subdirs 2>&1                      \
    | tee $ROBOLOG

EXIT_STATUS=$?

echo "    ===================================="
echo "    ======== ROBO ERROR SUMMARY ========"
echo "    ===================================="

grep -e '[Ee]rror:' -e '(S)' -e ' Error ' $ROBOLOG

exit $EXIT_STATUS