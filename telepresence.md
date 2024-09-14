telepresence helm install
telepresence connect -n vector
telepresence intercept vector --port 18080:80 --service vector --env-file vector-env-vars
telepresence leave vector
telepresence quit