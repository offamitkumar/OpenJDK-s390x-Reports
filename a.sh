#!/bin/bash

# Get the current year, month, and day
year=$(date +%Y)
month=$(date +%B)
day=$(date +%d)

git_setup() {
  # Check if the branch exists in the remote or locally
  if git show-ref --verify --quiet refs/heads/"$year"; then
    echo "Branch '$year' already exists."
  else
    # Create and switch to the new branch
    git checkout -b "$year"
    echo "Branch '$year' created and checked out."
  fi
}

set_directories() {
  # Check if the year directory exists
  if [ ! -d "$year" ]; then
    mkdir "$year"
  fi

  # Check if the month directory inside the year directory exists
  if [ ! -d "$year/$month" ]; then
    mkdir "$year/$month"
  fi

  # Check if the day directory inside the month directory exists
  if [ ! -d "$year/$month/$day" ]; then
    mkdir "$year/$month/$day"
  fi
}

git_exit() {
  git add .
  git commit -m "$day/$month/$year"
  git push
}

git_setup
set_directories
git_exit
