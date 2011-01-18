This is stolen totally from git by Junio C. Hamano. I like it,
so this is how we rock the main repository.

The document contains the general policy and further down some hints
on submitting patches.

# The policy.

 * Feature releases are numbered as vX.Y and are meant to
   contain bugfixes and enhancements in any area, including
   functionality, performance and usability, without regression.

 * Maintenance releases are numbered as vX.Y.W and are meant
   to contain only bugfixes for the corresponding vX.Y feature
   release and earlier maintenance releases vX.Y.V (V < W).

 * 'master' branch is used to prepare for the next feature
   release. In other words, at some point, the tip of 'master'
   branch is tagged with vX.Y.

 * 'maint' branch is used to prepare for the next maintenance
   release.  After the feature release vX.Y is made, the tip
   of 'maint' branch is set to that release, and bugfixes will
   accumulate on the branch, and at some point, the tip of the
   branch is tagged with vX.Y.1, vX.Y.2, and so on.

 * 'next' branch is used to publish changes (both enhancements
   and fixes) that (1) have worthwhile goal, (2) are in a fairly
   good shape suitable for everyday use, (3) but have not yet
   demonstrated to be regression free.  New changes are tested
   in 'next' before merged to 'master'.

 * 'pu' branch is used to publish other proposed changes that do
   not yet pass the criteria set for 'next'.

 * The tips of 'master', 'maint' and 'next' branches will always
   fast forward, to allow people to build their own
   customization on top of them.

 * Usually 'master' contains all of 'maint', 'next' contains all
   of 'master' and 'pu' contains all of 'next'.

 * The tip of 'master' is meant to be more stable than any
   tagged releases, and the users are encouraged to follow it.

 * The 'next' branch is where new action takes place, and the
   users are encouraged to test it so that regressions and bugs
   are found before new topics are merged to 'master'.

# Submitting patches

## Configuring gits user information

First, configure git so the patches have the right names in them:

    git config --global user.name "Your Name Comes Here"
    git config --global user.email you@yourdomain.example.com

## Branching

  * Fork the project on github.
  * Clone the forked repo locally (Instructions are in the fork
    information)
  * Setup a remote, `upstream` to point to the main repository:

        git remote add upstream git://github.com/jlouis/etorrent

  * Now, create a topic-branch to hold your changes. You should pick
    the most stable branch which will support them. This is usually
    `master` though at times, it will be `next` or `maint`. Never use
    `pu` or any other branch, as they may be rewound and rewritten. If
    you *must*, make sure that the owner of the branch knows you are
    doing it, to avoid troubles later.

    You should pick a name for your topic branch which is as precise
    as you can make it.

  * In general, *avoid* merging `master` or `next` into your topic
    branch. Also, avoid blindly firing `git rebase master` to follow
    the development on `master`. For testing reintegration with
    master, git provides `git rerere`.

    The problem is that when your `topic` gets merged into master,
    there will be a large amount of 'merge' commits which are basically
    just noise (even though `git log` can filter them). Also, if merges
    from master to your branch is used sparingly, it conveys information:
    whenever you merge master in, you make it clear your `topic` depends
    on something new that arrived.

    Create a `test` branch and merge your `topic` plus `master` in to this
    to test your changes against master. Do the same with `topic`+`next` to
    test your branch against the cooking pot - so we get the cooking pot
    exercised a bit as well. You can use this to test different configurations
    of lurking patches and ideas with your code to flesh out problems long
    before they occur.

    the `git rerere` tool can track how conflicts are resolved, so you can
    destroy the `test` branch afterwards and recreate it since `rerere`
    will replay conflict resolutions for you. This also means that if you
    merge the tree differently or need to merge changes from master you need,
    then `rerere` will help you.

  * When you do several patches in a row, try to make it such that
    each commit provides a working tree. This helps tools like `git
    bisect` a lot. Aggressively cleanup your branches with `git rebase
    -i` before publishing. Other good patch-processing commands are
    `git add -i` and `git commit --amend`.

    Try to make each commit a separate change. I'd rather want 5 than
    one squashed.

    Try to write a good commit message: Give it a title that
    summarizes and a body that details the change, why it was done and
    how it was done. The why is more important than the how unless it
    is obvious (fixing a bug has an obvious why).

  * Publishing a branch is done with

        git push origin topic-feature-name

    I will usually first pull it to next and let it cook there for a
    couple of days before moving the patch further on to master --
    unless the change is trivially correct (Make fixes, documentation
    change and so on).

  * Cleanup after the patch graduated to master is done with

        git push origin :topic-feature-name

    this makes it easier for all of us to track what is still alive
    and what is not.


