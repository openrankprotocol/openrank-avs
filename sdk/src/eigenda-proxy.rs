https://github.com/Layr-Labs/eigenda-proxy/blob/main/clients/standard_client/client.go

https://github.com/Layr-Labs/eigenda/blob/master/api/clients/v2/coretypes/eigenda_cert.go

Steps:
1. https://github.com/Layr-Labs/rxp/blob/master/cmd/imagestore/main.go - this is a go code which pushes docker image to eigenda and then creates reservation and add images (using certs from eigenda) to our contracts
- Point to Dockerfile for the image

2. Run rxp node - provided by rxp scripts:
- Need to point it to correct ReservationRegistry
- Need to point it to correct ReexecutionEndpoint
