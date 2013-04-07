#!/bin/bash -x
HERE=$(dirname "$0")
HERE=$(cd "$0" ; pwd)
QT5="$HERE/qt5"
QT5BASE=$QT5/qtbase
PROCESSORS=$(cat /proc/cpuinfo | grep processor | wc -l)
if [ -e "$PROCESSORS" ]
then
    PROCESSORS=1
fi

function debian_init()
{
    APT_OPTION="-y -m -f -q"
sudo apt-get install $APT_OPTION \
    bison \
    build-essential \
    flex \
    git \
    gperf \
    libedit-dev \
    libglu1-mesa-dev \
    libicu-dev \
    libx11-xcb1 \
    libx11-xcb-dev \
    libxcb1 \
    libxcb1-dev \
    libxcb-atom1-dev \
    libxcb-aux0-dev \
    libxcb-composite0-dev \
    libxcb-damage0-dev \
    libxcb-dpms0-dev \
    libxcb-dri2-0-dev \
    libxcb-event1-dev \
    libxcb-glx0-dev \
    libxcb-icccm1 \
    libxcb-icccm1-dev \
    libxcb-image0 \
    libxcb-image0-dev \
    libxcb-keysyms1 \
    libxcb-keysyms1-dev \
    libxcb-randr0-dev \
    libxcb-record0-dev \
    libxcb-render0-dev \
    libxcb-render-util0 \
    libxcb-render-util0-dev \
    libxcb-res0-dev \
    libxcb-screensaver0-dev \
    libxcb-shape0-dev \
    libxcb-shm0 \
    libxcb-shm0-dev \
    libxcb-sync0 \
    libxcb-sync0-dev \
    libxcb-xevie0-dev \
    libxcb-xf86dri0-dev \
    libxcb-xfixes0-dev \
    libxcb-xinerama0-dev \
    libxcb-xprint0-dev \
    libxcb-xtest0-dev \
    libxcb-xv0-dev \
    libxcb-xvmc0-dev \
    libxcomposite-dev \
    libxrender-dev \
    libxslt-dev \
    perl \
    python \
    || exit 1

}

function cleanup()
{
cd $QT5 && git clean -xfd 
cd $QT5 && git submodule foreach --recursive 'git clean -dfx'
}

function checkout()
{
  git submodule init
  git submodule update
  cd $QT5 || exit 1

  ./init-repository -f || exit 1
}

function build_qt()
{
    #./configure -help
    ./configure -no-qpa-platform-guard -nomake tests -nomake demos -nomake tools -nomake examples -no-gtkstyle -no-pch -opensource -confirm-license -prefix $QT5BASE || exit 1
    make -j$PROCESSORS || exit
}


debian_init
checkout 
build_qt
exit 0
