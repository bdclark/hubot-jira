# Description:
#   Looks up jira issues when they're mentioned in chat
#
#   Will ignore users set in HUBOT_JIRA_IGNORE_USERS (by default, JIRA and GitHub).
#
# Dependencies:
#   None
#
# Configuration:
#   HUBOT_JIRA_URL (format: "https://jira-domain.com:9090")
#   HUBOT_JIRA_IGNORECASE (optional; default is "true")
#   HUBOT_JIRA_USERNAME (optional)
#   HUBOT_JIRA_PASSWORD (optional)
#   HUBOT_JIRA_IGNORE_USERS (optional, format: "user1|user2", default is "jira|github")
#
# Commands:
#   hubot move jira <issue ID> to <status> - Changes the status of <issue ID> to <status>
#   hubot jira status - List the available statuses
#
# Author:
#   rustedgrail
#   stuartf

module.exports = (robot) ->
  cache = []

  # In case someone upgrades form the previous version, we'll default to the
  # previous behavior.
  jiraUrl = process.env.HUBOT_JIRA_URL || "https://#{process.env.HUBOT_JIRA_DOMAIN}"
  jiraUsername = process.env.HUBOT_JIRA_USERNAME
  jiraPassword = process.env.HUBOT_JIRA_PASSWORD

  if jiraUsername != undefined && jiraUsername.length > 0
    auth = "#{jiraUsername}:#{jiraPassword}"

  jiraIgnoreUsers = process.env.HUBOT_JIRA_ISSUES_IGNORE_USERS
  if jiraIgnoreUsers == undefined
    jiraIgnoreUsers = "jira|github"

  robot.http(jiraUrl + "/rest/api/2/project")
    .auth(auth)
    .get() (err, res, body) ->
      json = JSON.parse(body)
      jiraPrefixes = ( entry.key for entry in json )
      reducedPrefixes = jiraPrefixes.reduce (x,y) -> x + "-|" + y
      jiraPattern = "/\\b(" + reducedPrefixes + "-)(\\d+)\\b/g"
      ic = process.env.HUBOT_JIRA_IGNORECASE
      if ic == undefined || ic == "true"
        jiraPattern += "i"
      jiraPattern = eval(jiraPattern)

      robot.hear /move jira (.+) to (.+)/, (msg) ->
        issue = msg.match[1]
        msg.send "Getting transitions for #{issue}"
        robot.http(jiraUrl + "/rest/api/2/issue/#{issue}/transitions")
          .auth(auth).get() (err, res, body) ->
            jsonBody = JSON.parse(body)
            status = jsonBody.transitions.filter (trans) ->
              trans.name.toLowerCase() == msg.match[2].toLowerCase()
            if status.length == 0
              trans = jsonBody.transitions.map (trans) -> trans.name
              msg.send "The only transitions of #{issue} are: #{trans.reduce (t, s) -> t + "," + s}"
              return
            msg.send "Changing the status of #{issue} to #{status[0].name}"
            robot.http(jiraUrl + "/rest/api/2/issue/#{issue}/transitions")
              .header("Content-Type", "application/json").auth(auth).post(JSON.stringify({
                transition: status[0]
              })) (err, res, body) ->
                msg.send if res.statusCode == 204 then "Success!" else body

      robot.hear /jira status/, (msg) ->
        robot.http(jiraUrl + "/rest/api/2/status")
        .auth(auth).get() (err, res, body) ->
          response = "```"
          for status in JSON.parse(body)
            response += status.name + ": " + status.description + '\n'
          response += "```"
          msg.send response

      robot.hear jiraPattern, (msg) ->
        return if msg.message.user.name.match(new RegExp(jiraIgnoreUsers, "gi"))
        return if msg.message.text.match(new RegExp(/move jira (.+) to (.+)/))

        for i in msg.match
          issue = i.toUpperCase()
          now = new Date().getTime()
          if cache.length > 0
            cache.shift() until cache.length is 0 or cache[0].expires >= now

          msg.send item.message for item in cache when item.issue is issue

          if cache.length == 0 or (item for item in cache when item.issue is issue).length == 0
            robot.http(jiraUrl + "/rest/api/2/issue/" + issue)
              .auth(auth)
              .get() (err, res, body) ->
                try
                  json = JSON.parse(body)
                  key = json.key
                  issueUrl = jiraUrl + "/browse/" + key
                  issueType = json.fields.issuetype.name
                  status = json.fields.status.name
                  summary = json.fields.summary
                  reporter = json.fields.reporter.displayName
                  priority = json.fields.priority.name
                  if (json.fields.assignee == null)
                    assignee = 'unassigned'
                  else if ('value' of json.fields.assignee or 'displayName' of json.fields.assignee)
                    if (json.fields.assignee.name == "assignee" and json.fields.assignee.value.displayName)
                      assignee = json.fields.assignee.value.displayName
                    else if (json.fields.assignee and json.fields.assignee.displayName)
                      assignee = json.fields.assignee.displayName
                  else
                    assignee = 'unassigned'
                  if json.fields.fixVersions and json.fields.fixVersions.length > 0
                    fixVersion = json.fields.fixVersions[0].name
                  else
                    fixVersion = 'NONE'

                  message = "[" + key + "] " + summary
                  message += '\nStatus: ' + status
                  message += ' | Reporter: ' + reporter
                  message += ' | Assignee: ' + assignee
                  message += ' | Priority: ' + priority
                  message += ' | Status: ' + status
                  message += ' | FixVersion: ' + fixVersion unless fixVersion == 'NONE'

                  text = "*Type:* :jira_#{issueType}: " + issueType
                  text += " | *Reporter:* " + reporter
                  text += " | *Assignee:* " + assignee
                  text += " | *Priority:* :jira_#{priority}: " + priority
                  text += " | *Status:* " + status
                  text += " | *FixVersion:* " + fixVersion unless fixVersion == 'NONE'

                  color = switch
                    when priority is "Minor" then 'good'
                    when priority is "Major" then 'warning'
                    when priority is "Critical" or "Blocker" then 'danger'
                    else '#28D7E5'

                  robot.emit 'slack.attachment',
                    fallback: message
                    message: msg.message
                    username: 'Jira'
                    icon_emoji: ':jira:'
                    content:
                      title: key + ': ' + summary
                      title_link: issueUrl
                      color: color
                      text: text
                      mrkdwn_in: ['text']

                  # urlRegex = new RegExp(jiraUrl + "[^\\s]*" + key)
                  # if not msg.message.text.match(urlRegex)
                  #   message += "\n" + jiraUrl + "/browse/" + key
                  #
                  # msg.send message
                  # cache.push({issue: issue, expires: now + 120000, message: message})
                catch error
                  try
                    msg.send "[*ERROR*] " + json.errorMessages[0]
                  catch reallyError
                    msg.send "[*ERROR*] " + reallyError
