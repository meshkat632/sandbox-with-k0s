output "key_pair_name" {
  description = "Name of the created EC2 key pair."
  value       = aws_key_pair.k0stool.key_name
}

output "key_pair_fingerprint" {
  description = "MD5 fingerprint of the public key, for verifying against 'aws ec2 describe-key-pairs'."
  value       = aws_key_pair.k0stool.fingerprint
}