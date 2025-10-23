#!/bin/bash

# Get the current year, month, and day
#year=$(date +%Y)
#month=$(date +%B)
#day=$(date +%d)
daily_builds="daily_builds"
directory_path="/home/amit/OpenJDK-s390x-Reports/$daily_builds"

# helper methods
git_setup() {
  git switch main
  git pull
  # Check if the branch exists in the remote or locally
  if git show-ref --verify --quiet refs/heads/"$daily_builds"; then
    git switch $daily_builds
    echo "Branch '$daily_builds' already exists."
  else
    # Create and switch to the new branch
    git checkout -b "$daily_builds"
    echo "Branch '$daily_builds' created and checked out."
  fi
}

set_directories_head() {

  if [ ! -d "$daily_builds" ]; then
    mkdir "$daily_builds"
  fi

  if [ ! -d "$daily_builds/head" ]; then
    mkdir "$daily_builds/head"
  fi

  if [ ! -d "$daily_builds/head/fastdebug" ]; then
    mkdir "$daily_builds/head/fastdebug"
  fi

  if [ ! -d "$daily_builds/head/release" ]; then
    mkdir "$daily_builds/head/release"
  fi
}

set_directories_jdk21() {

    if [ ! -d "$daily_builds/jdk21" ]; then
      mkdir "$daily_builds/jdk21"
    fi

    if [ ! -d "$daily_builds/jdk21/fastdebug" ]; then
      mkdir "$daily_builds/jdk21/fastdebug"
    fi

    if [ ! -d "$daily_builds/jdk21/release" ]; then
      mkdir "$daily_builds/jdk21/release"
    fi
}

set_directories_jdk17() {

    if [ ! -d "$daily_builds/jdk17" ]; then
      mkdir "$daily_builds/jdk17"
    fi

    if [ ! -d "$daily_builds/jdk17/fastdebug" ]; then
      mkdir "$daily_builds/jdk17/fastdebug"
    fi

    if [ ! -d "$daily_builds/jdk17/release" ]; then
      mkdir "$daily_builds/jdk17/release"
    fi
}

set_directories_jdk11() {

    if [ ! -d "$daily_builds/jdk11" ]; then
      mkdir "$daily_builds/jdk11"
    fi

    if [ ! -d "$daily_builds/jdk11/fastdebug" ]; then
      mkdir "$daily_builds/jdk11/fastdebug"
    fi

    if [ ! -d "$daily_builds/jdk11/release" ]; then
      mkdir "$daily_builds/jdk11/release"
    fi
}

git_exit() {
  git add .
  git commit -m "$(date)"
  git push --set-upstream origin $daily_builds
  git switch main # switch back to main
}

jdk_fastdebug() {
  export CONF=linux-s390x-server-fastdebug

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_25 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
    --with-debug-level=fastdebug \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_25 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
    --with-debug-level=fastdebug \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make images

  cp build/linux-s390x-server-fastdebug/build.log  $directory_path/head/fastdebug/

  make run-test-tier1;

  cp build/linux-s390x-server-fastdebug/test-results/test-summary.txt $directory_path/head/fastdebug

  cat $(find build/linux-s390x-server-fastdebug/ -name newfailures.txt) > $directory_path/head/fastdebug/newfailures.txt

  cat $(find build/linux-s390x-server-fastdebug/ -name other_errors.txt) > $directory_path/head/fastdebug/other_errors.txt
  #More test run with different JTREG Options

}

jdk_fastdebug_21() {
    export CONF=linux-s390x-server-fastdebug

    bash configure \
      --with-boot-jdk=$HOME/boot_jdk_21 \
      --with-jtreg=$HOME/jtreg \
      --with-gtest=$HOME/googletest \
      --with-debug-level=fastdebug \
      --with-native-debug-symbols=internal \
      --disable-precompiled-headers

    make clean;
    make dist-clean;

    bash configure \
      --with-boot-jdk=$HOME/boot_jdk_21 \
      --with-jtreg=$HOME/jtreg \
      --with-gtest=$HOME/googletest \
      --with-debug-level=fastdebug \
      --with-native-debug-symbols=internal \
      --disable-precompiled-headers

    make images

    cp build/linux-s390x-server-fastdebug/build.log  $directory_path/jdk21/fastdebug/

    make run-test-tier1;

    cp build/linux-s390x-server-fastdebug/test-results/test-summary.txt $directory_path/jdk21/fastdebug

    cat $(find build/linux-s390x-server-fastdebug/ -name newfailures.txt) > $directory_path/jdk21/fastdebug/newfailures.txt

    cat $(find build/linux-s390x-server-fastdebug/ -name other_errors.txt) > $directory_path/jdk21/fastdebug/other_errors.txt
      #More test run with different JTREG Options
}

jdk_fastdebug_17() {
    export CONF=linux-s390x-server-fastdebug

    bash configure \
      --with-boot-jdk=$HOME/boot_jdk_17 \
      --with-jtreg=$HOME/jtreg \
      --with-gtest=$HOME/googletest \
      --with-debug-level=fastdebug \
      --with-native-debug-symbols=internal \
      --disable-precompiled-headers

    make clean;
    make dist-clean;

    bash configure \
      --with-boot-jdk=$HOME/boot_jdk_17 \
      --with-jtreg=$HOME/jtreg \
      --with-gtest=$HOME/googletest \
      --with-debug-level=fastdebug \
      --with-native-debug-symbols=internal \
      --disable-precompiled-headers

    make images

    cp build/linux-s390x-server-fastdebug/build.log  $directory_path/jdk17/fastdebug/

    make run-test-tier1;

    cp build/linux-s390x-server-fastdebug/test-results/test-summary.txt $directory_path/jdk17/fastdebug

    cat $(find build/linux-s390x-server-fastdebug/ -name newfailures.txt) > $directory_path/jdk17/fastdebug/newfailures.txt

    cat $(find build/linux-s390x-server-fastdebug/ -name other_errors.txt) > $directory_path/jdk17/fastdebug/other_errors.txt
      #More test run with different JTREG Options
}

jdk_fastdebug_11() {
  export CONF=linux-s390x-normal-server-fastdebug

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_11 \
    --with-jtreg=$HOME/jtreg \
    --with-debug-level=fastdebug \
    --disable-warnings-as-errors \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_11 \
    --with-jtreg=$HOME/jtreg \
    --with-debug-level=fastdebug \
    --disable-warnings-as-errors \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make images

  cp build/linux-s390x-normal-server-fastdebug/build.log  $directory_path/jdk11/fastdebug/

  make run-test-tier1;

  cp build/linux-s390x-normal-server-fastdebug/test-results/test-summary.txt $directory_path/jdk11/fastdebug/

  cat $(find build/linux-s390x-normal-server-fastdebug/ -name newfailures.txt) > $directory_path/jdk11/fastdebug/newfailures.txt

  cat $(find build/linux-s390x-normal-server-fastdebug/ -name other_errors.txt) > $directory_path/jdk11/fastdebug/other_errors.txt

  #More test run with different JTREG Options
}

jdk_release() {
  export CONF=linux-s390x-server-release

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_25 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
    --with-debug-level=release \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_25 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
    --with-debug-level=release \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make images

  cp build/linux-s390x-server-release/build.log  $directory_path/head/release/

  make run-test-tier1;

  cp build/linux-s390x-server-release/test-results/test-summary.txt $directory_path/head/release/

  cat $(find build/linux-s390x-server-release/ -name newfailures.txt) > $directory_path/head/release/newfailures.txt

  cat $(find build/linux-s390x-server-release/ -name other_errors.txt) > $directory_path/head/release/other_errors.txt

  #More test run with different JTREG Options
}

jdk_release_21() {
  export CONF=linux-s390x-server-release

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_21 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
    --with-debug-level=release \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_21 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
    --with-debug-level=release \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make images

  cp build/linux-s390x-server-release/build.log  $directory_path/jdk21/release/

  make run-test-tier1;

  cp build/linux-s390x-server-release/test-results/test-summary.txt $directory_path/jdk21/release/

  cat $(find build/linux-s390x-server-release/ -name newfailures.txt) > $directory_path/jdk21/release/newfailures.txt

  cat $(find build/linux-s390x-server-release/ -name other_errors.txt) > $directory_path/jdk21/release/other_errors.txt

  #More test run with different JTREG Options
}

jdk_release_17() {
  export CONF=linux-s390x-server-release

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_17 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
    --with-debug-level=release \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_17 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
    --with-debug-level=release \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make images

  cp build/linux-s390x-server-release/build.log  $directory_path/jdk17/release/

  make run-test-tier1;

  cp build/linux-s390x-server-release/test-results/test-summary.txt $directory_path/jdk17/release/

  cat $(find build/linux-s390x-server-release/ -name newfailures.txt) > $directory_path/jdk17/release/newfailures.txt

  cat $(find build/linux-s390x-server-release/ -name other_errors.txt) > $directory_path/jdk17/release/other_errors.txt

  #More test run with different JTREG Options
}

jdk_release_11() {
  export CONF=linux-s390x-normal-server-release

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_11 \
    --with-jtreg=$HOME/jtreg \
    --with-debug-level=release \
    --disable-warnings-as-errors \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=$HOME/boot_jdk_11 \
    --with-jtreg=$HOME/jtreg \
    --with-debug-level=release \
    --disable-warnings-as-errors \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make images

  cp build/linux-s390x-normal-server-release/build.log  $directory_path/jdk11/release/

  make run-test-tier1;

  cp build/linux-s390x-normal-server-release/test-results/test-summary.txt $directory_path/jdk11/release/

  cat $(find build/linux-s390x-normal-server-release/ -name newfailures.txt) > $directory_path/jdk11/release/newfailures.txt

  cat $(find build/linux-s390x-normal-server-release/ -name other_errors.txt) > $directory_path/jdk11/release/other_errors.txt

  #More test run with different JTREG Options
}

build_test_jdk_head() {
  cd /home/amit/head/jdk
  git switch master
  git pull
  git log -1 > $directory_path/head/top_commit
  jdk_fastdebug;
  jdk_release;
  cd /home/amit/OpenJDK-s390x-Reports
}

build_test_jdk21() {
  cd /home/amit/head/jdk21u-dev
  git switch master
  git pull
  git log -1 > $directory_path/jdk21/top_commit
  jdk_fastdebug_21;
  jdk_release_21;
  cd /home/amit/OpenJDK-s390x-Reports
}

build_test_jdk17() {
  cd /home/amit/head/jdk17u-dev
  git switch master
  git pull
  git log -1 > $directory_path/jdk17/top_commit
  jdk_fastdebug_17;
  jdk_release_17;
  cd /home/amit/OpenJDK-s390x-Reports
}

build_test_jdk11() {
  cd /home/amit/head/jdk11u-dev
  git switch master
  git pull
  git log -1 > $directory_path/jdk11/top_commit
  jdk_fastdebug_11;
  jdk_release_11;
  cd /home/amit/OpenJDK-s390x-Reports
}

# usage
git_setup
set_directories_head
build_test_jdk_head
set_directories_jdk21
build_test_jdk21
set_directories_jdk17
build_test_jdk17
set_directories_jdk11
build_test_jdk11
git_exit #adds all the changes and do a git push
