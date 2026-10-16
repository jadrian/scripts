#!/usr/bin/env zsh

# Helper scripts wrapping core `jj` functionality.

# Handy references for scripting:
# - ZSH:  https://gist.github.com/ClementNerma/1dd94cb0f1884b9c20d1ba0037bdcde2
# - jj: https://docs.jj-vcs.dev/latest/revsets

jj-new-bookmark() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: jj-new-bookmark <name>"
        echo "Creates a new bookmark \`jsard-<name>\` and tracks it."
        return 1
    fi
    jj bookmark create "jsard-$1" && jj bookmark track "jsard-$1"
}


# Pushes the current change if it can best-effort figure out its bookmark.
# Also creates a new empty change if needed, to decrease the chance of
# clobbering an already-pushed change, which would look confusing on GitHub if
# pushed again.
jj-push() {
    # Just to provide context for what happens next...
    jj status
    echo ""
    
    local CURR_BM=$(jj bookmark list --tracked --revisions "@ & mine()")
    if [[ -n "$CURR_BM" ]]; then
        echo "Found a bookmark on the CURRENT change:"
        echo "$CURR_BM\n"
        if ! read -q "__?Continue with push? (y/n) "; then
            echo "\nOk, nevermind :)"
            return 1
        fi
        echo "\n"
        # For some reason, applying the template duplicates the bookmark name.
        # Appending "%%" and then stripping with `sed` deduplicates.
        local bm_name=$(jj-bookmark-name "@")
        jj git push && \
          __jj-maybe-new --quiet && \
          jj describe -m "Placeholder for edits to $bm_name"
        return 0
    fi

    local PREV_BM=$(jj bookmark list --tracked --revisions "@- & mine()")
    if [[ -n "$PREV_BM" ]]; then
        echo "Found a bookmark on the PARENT change:"
        echo "$PREV_BM\n"
        if ! read -q "__?Move this bookmark and then push? (y/n) "; then
            echo "\nOk, nevermind :)"
            return 1
        fi
        echo "\n"
        local bm_name=$(jj-bookmark-name "@-")
        jj bookmark move --from @- && \
          jj git push && \
          __jj-maybe-new --quiet && \
          jj describe -m "Placeholder for edits to $bm_name"
        return 0
    fi

    echo "Can't find a tracked bookmark to push. " \
      "Try \`jj log\` and \`jj-new-bookmark\`."
    return 2
}


jj-bookmark-name() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: jj-bookmark-name <change-id>"
        echo "Prints the name of the first bookmark found on this change."
        echo "\`change-id\` is required; if you want \`@\`, pass explicitly."
        return 1
    fi
    # There may be multiple bookmarks on one change, even if `jj log` shows just
    # one. (In particular, the same bookmark name often appears twice, for
    # reasons I haven't figured out.) `jj bookmark list` with just
    # `--template "name"` concatenates all of# them, so we add a "%%" separator
    # to strip away all but the first.
    jj bookmark list --revisions "$1 & mine()" --template "name ++ '%%'" \
    | sed "s/%%.*//g"
}


jj-check-out-remote-branch() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: jj-check-out-remote-branch <branch>"
        echo "Checks out \`branch\` from the remote origin."
        return 1
    fi
    git switch "$1" && \
      git pull origin "$1" && \
      jj status
}


# TODO: jj-rebase-children-on-head()
# Give it an old head; it rebases all children onto the latest head.


jj-rebase-on-head() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: jj-rebase-on-main <change-id>"
        echo "Rebases the given change (and descendants) on head."
        echo "\`change-id\` is required; if you want \`@\`, pass explicitly."
        return 1
    fi
    local target="$1"

    # Show us what we're working with.
    jj log -r "(${target}):: | (${target})-"
    echo
    
    # Fetch new changes.
    echo "Fetching from origin..."
    jj git fetch

    # Identify the new origin head commit.
    local new_head=`jj log -r 'trunk()' --no-graph --template 'change_id'`
    echo "\n+++ NEW head change to become parent of '${target}':"
    jj log -r "$new_head" --no-graph

    # Identify the parent that used to be origin head, plus all others.
    # This `jj log` call creates a CSV with a row per parent and two columns:
    # change ID, is_old_head.
    local parents=` \
        jj log -r "$target" --no-graph \
        --template ' \
            parents.map(|c| \
                c.change_id() ++ "," ++ \
                c.contained_in("ancestors(trunk())") \
            ).join("\n")'`
    local parents=("${(@f)parents}")  # Split on newline into array.
    local non_main_parents=()
    local found_main_parent=false
    local noop_rebase_likely=false
    for line in $parents; do
        parts=(${(@s:,:)line})  # Split on `,` into array.
        local ch_id="$parts[1]"
        if [[ "$parts[2]" == "true" ]]; then
            echo "\nxxx REPLACE old remote-main parent ${ch_id:0:8} of '${target}':"
            jj log -r "$ch_id" --no-graph

            if [[ $ch_id = $new_head ]]; then
                noop_rebase_likely=true
            fi

            if [[ $found_main_parent = true ]]; then
                echo "!!!"
                echo "!!! WARNING: found more than one old remote-main parent!"
                echo "!!!"
                noop_rebase_likely=false
            fi
            found_main_parent=true
        else
            echo "\n=== KEEP local/branch parent ${ch_id:0:8} of '${target}':"
            jj log -r "$ch_id" --no-graph

            non_main_parents+=("$ch_id")
        fi
    done
    echo

    # Build up the rebase command.
    local cmd="jj rebase --source ${target}"
    cmd="${cmd} --onto ${new_head}"
    for p in $non_main_parents; do
        cmd="${cmd} --onto ${p}"
    done
    echo $cmd
    echo

    if [[ $found_main_parent = false ]]; then
        echo "!!! Rev '${target}' does not currently have a remote-main parent."
        echo "!!! This rebase would add a new parent, which you may not want."
        echo
    fi

    if [[ $noop_rebase_likely = true ]]; then
        echo "!!! This rebase would likely be a no-op, since REPLACE == NEW."
        echo
    fi

    # Confirm and do it!
    if ! read -q "__?Rebase rev '${target}' and descendants? (y/n) "; then
        echo "\nOk, nevermind :)"
        echo "Note, though, that this command already did a \`jj git fetch\`."
        echo "You may want to \`jj undo\` it or check \`jj op log\`."
        return 1
    fi
    echo "\n"

    eval $cmd

    # Now show the new state.
    echo
    jj log -r "(${target}):: | (${target})-"
}

# Calls `jj new` only if the current change is non-empty or it has a non-empty
# description. It's unlikely an interactive user would ever need this, hence the
# "__".
#   This is useful because jj may sometimes automatically create a new empty
# change, and we don't want to be redundant. (For example, one might configure
# jj to treat pushed changes as immutable, in which case `jj git push`
# automatically calls `jj new` after the push.)
__jj-maybe-new() {
    # This var is the empty string if the current change has no contents and
    # also no description.
    CHANGE_AND_DESCRIPTION=$(jj log -r '@ & (~empty() | ~description(""))')
    # `-n` means "defined and not empty". So if we DO have changes OR a
    # description.
    if [[ -n "$CHANGE_AND_DESCRIPTION" ]]; then
        # $@ lets the caller pass args to `new`; they're blindly forwarded.
        jj new "$@"
    fi
}
