# DS Bot

DS Bot is a plugin on the host. Each Bot has its own role, chat and memory. Open DS Bot from All features, or tap [Open](dshgo://open/ds-bot). Check the host name at the top: the Bots and group chats below belong to that host.

## Mobile support

**DS Bot isn't on mobile yet** means this host's DS Bot has no usable mobile interface. Tap **Open in DSH Web** to use it there for now. After the plugin is updated and restarted on the host, tap **Retry** to check again. This message doesn't mean your Bots or group chats have been deleted.

If DS Bot isn't detected, the page offers installation or a command to run on the computer. Bots aren't available over DSH Remote; connect to that computer through SSH instead. For the web interface, open DSH Web on the computer.

## Working directory

Open a Bot or group chat, open its details from the top bar, then tap **Working directory**. You are choosing a directory on the connected host; a remote host's directories aren't on your phone.

1. Check **Current directory** and choose from the directories supplied by the host.
2. Tap **Save**, check the directory shown in “Use this working directory?”, then tap **Save** again.

For a Bot, choose **Team workspace** to restore the default. For a group chat, choose **Each Bot’s own directory** to let members use their individual working directories.

If the connection or folder has changed, close the sheet and open it again. If the host refuses a directory, it may be gone, inaccessible or protected; choose another or retry.

## Duplicate a Bot

In the Bot's details, tap **Duplicate Bot**, read the explanation and confirm. The new Bot keeps its job, instructions and model settings, starts with a fresh chat and personal memory, and gets its name from the host. When a model is available, it opens with a greeting.

After copying, the app normally opens the new Bot. If it says the copy will appear in the list shortly, return to the DS Bot list to check; you don't need to duplicate it again. If disconnected, on a different host or in read-only mode, restore the connection and reopen the details before trying.

## Group goals

Once a group chat has a standing goal, a **Group goal** card sits under the chat, titled with the goal's own name. Its status is at the top right: **Drafting**, **Active**, **Paused**, **Complete** or **Stopped**.

The card names the current stage, or the goal itself when there are no stages. With stages it also carries a progress bar with a line like "Stage 2 of 4" and "1 stages passed". Tapping the card's footer opens the whole ledger, where each stage takes a row:

- The icon on the left is a tick for a finished stage, a busy mark for the running one and a hollow mark for one not started. The current stage has a slightly darker background and a bolder title.
- Under a stage come its acceptance note, a line "Sent back 2 times" when it has been, a line "Sent back: ..." with the reason, and each task in that stage. A task row reads "name · task" with **Not started**, **Working**, **Reported** or **Done** on the right.
- The end of the ledger lists **Goal**, **Done when** and **Rules** (one bullet each). A goal that has finished also shows **Stopped because**, **Delivered** and **Evidence**, whichever of them is filled in.

When a status cannot be read, the goal and the task both fall back to **Unknown**. A stage row carries no status word; the icon on its left shows where it stands.

The group chat's details page lays the same ledger out directly, without the extra tap.

## Agent teams

<!-- nav: catalogAllFeatures,catalogAgentTeam -->
`All features › Agent team` · [Open](dshgo://open/agent-team)

In a team chat several agents split one job and share a task board. Besides All features, the capsule in the chat's top bar opens the same page: it shows the member count, with a breathing dot on the corner while any of them runs.

The top of the page stacks the captain's and members' avatars, titled with the captain's chat name; the line under it says how many members are working, or that they are all on standby. The stats row gives members, tasks and completed. Below that are three tabs: **Members**, **Tasks** and **Messages**.

- **Members**: one row each, with the duty and model underneath (the captain's row says **Owner**), and the one you are looking at marked **Current**. Tap one to open that agent's chat; the back arrow at the top left returns here. The one you are already in and those that have left do not respond.
- **Tasks**: grouped as **To do**, **In progress** and **Done**. Open one and its state is **Ready to start**, **Waiting on dependencies**, **In progress** or **Completed**; below come the description, **Owner** (**Unassigned** when nobody owns it), **ID**, **Dependencies** and **Write scopes**. When two tasks change the same files that row says **Overlapping write scopes** instead.
- **Messages**: what members sent each other, with sender, recipient and time. When only part of it was read, a line above the list says **Some members’ messages didn’t load · Retry**; with nothing at all it says **No messages between members yet**.

With the team off the page shows **Agent team is off**, one line of explanation and a **Turn on team** button that reads **Turning on…** while it runs. A host without the plugin shows **No agent team on this host**. With the plugin on but nobody recruited, the members tab ends with **Ask AI to form a team in a chat** — teams are formed in a chat, not created here. When the team can't be read the page says **Couldn’t load the team** and offers **Retry**.

## Team panel

<!-- nav: catalogAllFeatures,ateamCatalogTitle -->
`All features › Agent Teams`

This page belongs to the Agent Teams plugin and is not the official team above: it reads the plugin's own snapshot, so it can review a staged plan, show task dependencies, read the captain inbox and halt the whole team.

Once AI has formed a team in a chat, that tool result becomes a team card: name, phase, member count and the member avatars. The card itself and the key at its top right both open this panel.

The top stacks the member avatars and the team name, with a dot and the phase under it: **Awaiting approval**, **Running** or **Archived**, and **The team is halted** once it was stopped. The stats row gives members, open tasks and inbox messages. At the top right, **Halt team** while it runs and **Retry** at any time. Below are four tabs: **Overview**, **Members**, **Tasks** and **Captain inbox**.

- **Overview**: the captain's row comes first (subtitle **Captain**, with **Working** or **Idle** at the right and nothing when he holds no task), then the members that are working with their done/total, then the newest inbox entries. With none of those it falls back to three rows: phase, member count and task count.
- **Members**: one row each, the name as title, the **Current task** or the role underneath and done/total plus unread at the right. A member that left is marked **Left**.
- **Tasks**: grouped as "Lane 1", "Lane 2" when there are levels, and simply titled **Tasks** with one level. Each carries a state: **Ready**, **Claimed**, **Running**, **Waiting on dependencies**, **Completed**, **Failed** or **Cancelled**; a quality task also carries **Quality gate** and a stale one **Verdict is stale**. Open one for **Assignee**, **ID**, **Model**, **Dependencies**, plus "Round N" and "Verdict: ..." where they exist.
- **Captain inbox**: what the captain and the members sent each other. With nothing at all it says **The captain inbox is empty**; otherwise a line at the top of the list gives the message count.

While a plan waits for your call, a card sits above the tabs reading **The plan waits for your review** or **The plan waits for your feedback**, with three buttons: **Approve & run**, **Discuss further** and **Discard plan**. **Halt team** first asks "Halt the whole team?" — every member stops its turn and the team stays where it is; **Discard plan** asks "Discard this plan?" — the plan is archived and can no longer be approved.

When delivery has blockers or warnings another card appears: **Ready to deliver** or **Not deliverable yet** as its title, then a **Quality loop** line reading **Quality loop running**, **Quality loop: deliverable**, **Quality loop blocked**, **Quality loop escalated** or **Quality loop halted**; below come **Blockers**, **Warnings**, **The team is halted** and **Description** (the team's working directory).

A host without the plugin says **This host does not have the Agent Teams plugin**; one with the plugin off says **The Agent Teams plugin is off**, with the plugin's own description and **Enable Agent Teams**, which reads **Enabling…** while it runs; a plugin with no team yet says **No teams yet**; an unreadable one says **Could not read the team state** with **Retry**. Offline, the page keeps only the offline note.
