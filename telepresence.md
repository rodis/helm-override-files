telepresence helm install
telepresence connect -n vector
telepresence intercept vector --port 18080:80 --service vector --env-file vector/vector-env-vars



# Remove
telepresence leave vector
# unistall the traffic agent running on kube 
telepresence helm uninstall
# Quit local deamon
telepresence quit -s