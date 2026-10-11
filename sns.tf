resource "aws_sns_topic" "events" {
  for_each = toset(local.sns_topics)

  name                        = "${each.key}.fifo"
  fifo_topic                  = true
  content_based_deduplication = false

  tags = { Name = "${each.key}.fifo" }
}
